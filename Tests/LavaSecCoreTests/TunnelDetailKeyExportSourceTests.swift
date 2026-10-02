import XCTest
import Foundation

@testable import LavaSecCore

/// Every detail key the packet tunnel logs must be a DECIDED key: either exported in a bug
/// report, or explicitly withheld here.
///
/// ## Why this exists
///
/// `BugReportBundle.allowedDetailKeys` filters the device debug log on its way into a report, and
/// a key missing from it is dropped SILENTLY — the event still exports, with the reading gone.
/// That has now happened three times. PR #580 fixed the first occurrence, after 1,076 lines
/// across 15 event kinds exported as `"details": {}` and a field log could not be diagnosed. The
/// gap then reopened for the two chained features added since, and cost a second investigation on
/// 2026-08-28: an export showed `data-path-latched` carrying three of its four keys and
/// `chained-session-liveness` carrying 31 of its 33. Every key present was allowlisted and every
/// key absent was not — but from the outside that is indistinguishable from an extension binary
/// predating those features, which is what it was diagnosed as first, wrongly.
///
/// The third was found by this test rather than by a field report, and only after the extractor
/// was taught to read payloads the tunnel does not compose inline (Codex, PR #615):
/// `chained-data-path-pressure` has been emitting `admission`, `bytes`, `packets` and
/// `queueDepth` from an unconditional production path, none of them exported, since the recorder
/// was introduced. Three occurrences in three different shapes is why the check is now over the
/// PAIR of emitter and allowlist, mechanically, rather than over anyone remembering.
///
/// The failure is invisible from either side alone. The emitter looks correct, the allowlist
/// looks correct, and only the pair is wrong — so the pair is what this checks. And the check
/// must see EVERY payload: a key extractor that quietly skips an argument form it cannot read
/// reproduces the same silent drop one level up, which is exactly how those four pressure keys
/// survived this file's first version.
///
/// ## What this test is NOT
///
/// It is not the guarantee. It reads Swift as text, and a text reader can always be evaded by a
/// shape it does not parse — five review rounds on PR #615 produced five such shapes, each one
/// real, and there is no reason to think the sixth does not exist. Every round's fix is here, but
/// the honest claim is "catches the shapes it knows", not "cannot be evaded".
///
/// The guarantee lives in `BugReportBundle` instead, and does not depend on this file or on
/// anyone maintaining a list: an entry that lost keys to the allowlist says HOW MANY (`_withheld`),
/// whatever the emitter looked like. A count rather than the names, because a key name is only
/// schema while every emitter writes it as a literal — see
/// `BugReportBundleTests.testWithheldFieldCarriesACountAndNeverAKeyName`. That is what makes the
/// failure mode diagnosable rather than invisible, which was the actual problem. This test's job
/// is to catch the key before it ships; that one's job is to make sure nobody is misled if it
/// does not.
///
/// ## Why it is not "every key must be exported"
///
/// That test would be worse than none. `domain` carries the QUERIED DOMAIN — verified at all
/// three of its emitters (`chained-aaaa-nodata`, `chained-ipv6hint-stripped`,
/// `chained-dns-leak-canary-fired`) — and a test demanding it be allowlisted would pressure a
/// future author into putting browsing history in a user-shareable bundle to get CI green. The
/// allowlist's whole purpose is to keep queried domains out. So the requirement is a DECISION,
/// not an outcome: allowlist the key, or name it below.
final class TunnelDetailKeyExportSourceTests: XCTestCase {
    /// Keys that must NEVER be exported, whatever a future change wants.
    ///
    /// Audited, in two groups. `domain` carries a domain the user actually resolved, at all
    /// three of its emitters. `identity` and `sessionID` are opaque but identity-shaped, and
    /// `BugReportBundle` names them in its own "DELIBERATELY NOT ADDED" note — they were
    /// considered and rejected there, so filing them under ``unauditedLegacyKeys`` would have
    /// made that list's honesty claim false (Kilo, PR #615).
    private static let withheldByPolicy: Set<String> = [
        "dnsPatchObservedAddresses", // Carrier-specific translated resolver IPs stay in local diagnostics.
        "domain",
        "identity",
        "sessionID"
    ]

    /// Bounded local diagnostics deliberately excluded from report export.
    /// Round 8 explicitly authorized its investigation fields without expanding report export.
    /// Recorded in lavasec-infra/docs/product/design-evidence/ios-interface-v2/2026-09-14-round8.md (R17 implementation/qualification).
    /// These are audited counts/closed-set labels, not secret payloads; withholding preserves that
    /// collection boundary rather than declaring them intrinsically unsafe. Exporting them needs a
    /// separate explicit scope decision. Keep each purpose visible instead of exempting an emitter.
    private static let withheldLocalInvestigationKeys: Set<String> = [
        "processID",                    // QA update investigation: correlate local provider lifetimes only.
        "seconds",                      // Local QA peer-outage injection duration, not production telemetry.
        "sentDrops",                    // Datagrams deliberately discarded by the local QA injector.
        "receivedDrops",                // Datagrams deliberately discarded by the local QA injector.
        "outboundInputPackets",          // All input at the live driver, including DNS and drops.
        "outboundWithoutRunnerPackets",  // Input admitted while no current runner exists.
        "dnsHandledPackets",             // Packets handed to the filtered DNS path.
        "malformedPackets",              // Outbound packet-structure rejections.
        "unfilterableDNSPackets",        // DNS packets rejected by the safe classifier boundary.
        "unfilterableEncryptedDNSPackets", // Directly identified port-853 policy drops; disjoint from generic DNS drops.
        "droppedOutboundIPv6Packets",    // IPv6 packet-policy drops, not destinations.
        "encapsulationAttempts",         // Engine calls, never delivered/forwarded proof.
        "parseFailureCategory"           // Closed DNS parser failure class, never query content.
    ]

    /// Keys that predate this test and are NOT audited — neither exported nor justified.
    ///
    /// Frozen rather than blessed. This list is the honest state of the codebase on 2026-08-28,
    /// not a claim that any of these SHOULD be withheld: auditing them is separate work, and
    /// several are probably safe counters that belong in reports. What the freeze buys is that a
    /// NEWLY added key cannot join them by accident — it fails this test until someone decides.
    ///
    /// A key should leave this list in one direction only: audited, then either allowlisted in
    /// `BugReportBundle` or moved to ``withheldByPolicy`` with its reason. Adding a new key here
    /// to silence a failure is the one use this list is not for.
    ///
    /// It also lost one entry that was never a key at all: `missing` came from
    /// `enabledBlocklistIDs.isEmpty ? "missing" : "fail-closed"` inside a payload, read as a key
    /// by an unanchored regex. Anchoring the key match to its `[` or `,` deleted the phantom
    /// (Codex, PR #615).
    private static let unauditedLegacyKeys: Set<String> = [
        "anchored", "attempts", "attemptsRemaining", "backoffIntervalS", "cause", "changed",
        "chronicFailures", "consequence", "enabled", "hasOperationID", "hasOptions",
        "maxFilterRules", "mode", "nonce", "pauseActive", "reasonName",
        "recoveredAfterMs", "restartReason", "routesToEncryptedFallback",
        "sinceLastProbeS", "tierBudgetRuleCount", "trigger", "usedTCP", "verification",
        "windowHostCount", "wire"
    ]

    func testEveryTunnelDetailKeyIsExportedOrExplicitlyWithheld() throws {
        let emitted = try Self.tunnelDetailKeys()
        let exported = try Self.exportAllowlist()

        XCTAssertFalse(emitted.isEmpty, "the extractor found no detail keys — it has broken")
        XCTAssertFalse(exported.isEmpty, "the allowlist extractor found no keys — it has broken")

        let undecided = emitted
            .subtracting(exported)
            .subtracting(Self.withheldByPolicy)
            .subtracting(Self.withheldLocalInvestigationKeys)
            .subtracting(Self.unauditedLegacyKeys)

        XCTAssertTrue(
            undecided.isEmpty,
            """
            These tunnel detail keys are neither exported nor explicitly withheld, so they are \
            dropped SILENTLY from every bug report: \(undecided.sorted().joined(separator: ", ")).

            Decide, do not just silence: add the key to `BugReportBundle.allowedDetailKeys` if it \
            is a counter/bool/duration/closed-set label with no queried domain, or to \
            `withheldByPolicy` here with the reason it must stay out. Do NOT add it to \
            `unauditedLegacyKeys` — that list is frozen at its 2026-08-28 contents.
            """
        )
    }

    /// The three keys the 2026-08-28 investigation found missing, pinned by name.
    ///
    /// The general check above would pass if these were moved into `unauditedLegacyKeys`, which
    /// is exactly the shortcut that would re-hide them. Naming them makes that a visible edit.
    func testTheChainedDiagnosticsFoundMissingOn20260828AreExported() throws {
        let exported = try Self.exportAllowlist()
        for key in ["unansweredDests", "longestUnansweredSecs", "upstreamGeneration"] {
            XCTAssertTrue(
                exported.contains(key),
                "\(key) must reach a bug report — it is a counter/duration/identifier with no "
                    + "queried domain, and its absence is what made a current build read as stale")
        }
    }

    /// The connect gate's own diagnostic fields, pinned by name for the same reason.
    ///
    /// These three shipped in PR #598 EXPRESSLY to tell three failure shapes apart — a gate that
    /// never started (no line), a stuck one (`cancelled` with a high `polls`), and an extension
    /// not answering the IPC (`unknownReplies` tracking `polls`). None of them reached the export:
    /// every `chained-establish-gate` line rendered as `_withheld: 3`, so when the gate failed
    /// three times on device (2026-08-30) the evidence had to be rebuilt from tunnel-side
    /// counters. Telemetry that cannot leave the device is not telemetry.
    func testTheConnectGateDiagnosticsAreExported() throws {
        let exported = try Self.exportAllowlist()
        for key in ["polls", "unknownReplies", "receivedDelta"] {
            XCTAssertTrue(
                exported.contains(key),
                "\(key) must reach a bug report — it is the chained-connect gate's own counter, "
                    + "carrying no domain, address or timestamp, and without it the gate's outcome "
                    + "line cannot be told apart from a gate that never ran")
        }
    }

    /// The withheld keys must never be exported, and this asserts the ABSENCE.
    ///
    /// The rest of this file is about keys going missing; this is the one direction where the
    /// dangerous change is a key APPEARING. It is also the enforcement half of
    /// `BugReportBundle`'s "DELIBERATELY NOT ADDED" note, which until now was an unpinned claim.
    func testTheWithheldKeysAreNeverExported() throws {
        let exported = try Self.exportAllowlist()
        XCTAssertFalse(
            exported.contains("domain"),
            "`domain` carries the domain the user resolved — allowlisting it would put browsing "
                + "history in a user-shareable bundle")
        for key in ["identity", "sessionID"] {
            XCTAssertFalse(
                exported.contains(key),
                "`\(key)` is identity-shaped and was deliberately excluded in `BugReportBundle`; "
                    + "it diagnoses no tunnel fault and adding it must be a decision, not a drift")
        }
    }

    func testRound8LocalInvestigationFieldsDoNotExpandReportExport() throws {
        let emitted = try Self.tunnelDetailKeys()
        let exported = try Self.exportAllowlist()
        for key in Self.withheldLocalInvestigationKeys {
            XCTAssertTrue(emitted.contains(key),
                "Remove or re-audit a retired local diagnostic rather than keeping a stale exemption: \(key)")
            XCTAssertFalse(exported.contains(key),
                "\(key) was authorized for local investigation only; report export needs an explicit scope decision.")
        }
    }

    /// Every `details:` argument must be in a form this extractor understands.
    ///
    /// The first version of this test read inline `details: [ … ]` literals and SKIPPED every
    /// other argument form. That is the same silent-drop shape the test is meant to prevent,
    /// one level up: `PacketTunnelProvider` assembles payloads as `var details = [ … ]` plus
    /// conditional subscripts, forwards recorder-built payloads as `emission.details`, and
    /// passes helper results like `Self.errorDebugDetails(error)` — and the skip kept all of
    /// them out of the check while other literals kept the key set non-empty and the test
    /// green (Codex, PR #615). Four production keys were hiding behind exactly that skip.
    ///
    /// So an unrecognised form is now a FAILURE rather than a `continue`. A new argument shape
    /// means teaching the extractor to trace it, or naming it in ``relayedDetailArguments``
    /// with the producer added to ``relayProducers``.
    func testEveryDetailPayloadArgumentIsAccountedFor() throws {
        var unresolved: [String: Set<String>] = [:]
        for file in SourceFile.packetTunnelProviderSources + Self.relayProducers {
            let forms = try Self.detailPayload(in: file).unresolved
            if !forms.isEmpty { unresolved[file.rawValue] = forms }
        }

        XCTAssertTrue(
            unresolved.isEmpty,
            """
            These `details:` arguments are in a form the key extractor cannot read, so every key \
            they carry is unchecked against the export allowlist: \
            \(unresolved.map { "\($0.key): \($0.value.sorted().joined(separator: ", "))" }
                .sorted().joined(separator: "; ")).

            Trace the form (see `assembledDetailVariables` / `detailBuildingHelpers`), or add \
            the expression to `relayedDetailArguments` AND its producing file to \
            `relayProducers` so the keys are extracted there instead.
            """
        )
    }

    /// The relay producers must still be producing.
    ///
    /// ``relayProducers`` is the load-bearing half of the relay decision: the arguments in
    /// ``relayedDetailArguments`` are only safe to skip because the file that composes them is
    /// extracted instead. A producer that is renamed, emptied, or has its emission reshaped
    /// would go on passing silently, so each one is required to yield keys.
    func testEveryRelayProducerStillYieldsKeys() throws {
        for producer in Self.relayProducers {
            XCTAssertFalse(
                try Self.detailPayload(in: producer).keys.isEmpty,
                "\(producer.rawValue) is listed as composing forwarded detail payloads but the "
                    + "extractor found no keys in it — its emission shape changed, and the keys "
                    + "it now builds are unchecked")
        }
    }

    /// The chained data-path pressure counters this test found unexported, pinned by name.
    ///
    /// Same reasoning as the 2026-08-28 pin below: the general check would pass if these were
    /// filed under `unauditedLegacyKeys`, which is the shortcut that re-hides them.
    func testTheChainedDataPathPressureCountersAreExported() throws {
        let exported = try Self.exportAllowlist()
        for key in ["admission", "bytes", "packets", "queueDepth"] {
            XCTAssertTrue(
                exported.contains(key),
                "\(key) is emitted by `chained-data-path-pressure` on an unconditional "
                    + "production path and must reach a bug report — it is a counter or a "
                    + "closed-set label, with no queried domain")
        }
    }

    // MARK: - Extraction

    /// Files that COMPOSE detail payloads the tunnel forwards verbatim.
    ///
    /// The tunnel does not build every payload it logs. Transport sinks and the chained
    /// diagnostics recorder hand it a finished dictionary, which it passes straight to
    /// `LavaSecDeviceDebugLog.append`. Those keys reach a bug report by exactly the same route
    /// and are dropped by exactly the same allowlist, so they are EXTRACTED here rather than
    /// excused — and the first one traced was already broken: `chained-data-path-pressure`
    /// emits `admission`/`bytes`/`packets`/`queueDepth` from
    /// `ChainedTransportDiagnosticsRecorder.recordPressure`, an unconditional production path,
    /// and none of the four was allowlisted until this test found them (PR #615).
    ///
    /// Adding a new relay sink to the tunnel means adding its producer here; leaving it out
    /// fails ``testEveryDetailPayloadArgumentIsAccountedFor``, not this list.
    private static let relayProducers: [SourceFile] = [
        .appGroup,
        .chainedTransportDiagnosticsRecorder,
        .doHTransport,
        .doTTransport,
        .doQTransport,
        .latencyTrace
    ]

    /// Local variable names assembled by subscript before being logged.
    ///
    /// The common shape is `var details = [ … ]` followed by conditional `details["k"] = …`,
    /// and reading only the initializer literal loses every conditional key — which is how
    /// `raw`, `masked`, `suppressedRepeats` and `sqliteCode` stayed invisible to the first
    /// version of this test (Codex, PR #615).
    ///
    /// Tracing is by NAME across the whole file, not by scope. That over-collects if an
    /// unrelated function ever assigns `someDict["k"]` to a variable of the same name, and the
    /// asymmetry is deliberate: over-collection costs a spurious decision, under-collection
    /// costs a silently dropped diagnostic, which is the failure this whole file exists for.
    private static let assembledDetailVariables = ["details", "output"]

    /// Helpers that RETURN a prepared payload, traced into their bodies.
    ///
    /// `Self.errorDebugDetails(error)` and `LatencyEvent.debugLogDetails(…)` appear as the
    /// `details:` argument with no literal in sight; their keys live in the function body.
    private static let detailBuildingHelpers = ["errorDebugDetails", "debugLogDetails"]

    /// Argument expressions that name a payload built in a ``relayProducers`` file.
    ///
    /// Anything not a literal, an assembled variable, a helper call, or one of these fails
    /// ``testEveryDetailPayloadArgumentIsAccountedFor``. That is the whole point: an argument
    /// form this extractor does not understand must be loud, because a form it silently skips
    /// is a key it silently drops.
    private static let relayedDetailArguments: Set<String> = [
        "emission.details"
    ]

    /// Detail keys the tunnel logs, plus the keys its relay producers compose.
    private static func tunnelDetailKeys() throws -> Set<String> {
        var keys: Set<String> = []
        for file in SourceFile.packetTunnelProviderSources + relayProducers {
            keys.formUnion(try detailPayload(in: file).keys)
        }
        return keys
    }

    /// Every detail key one file contributes, and every argument form it could not resolve.
    ///
    /// Three passes: every dictionary literal, every key assembled by subscript, and an
    /// accounting check that no payload argument is in a form whose provenance is unknown.
    private static func detailPayload(
        in file: SourceFile
    ) throws -> (keys: Set<String>, unresolved: Set<String>) {
        let source = maskedForStructure(try readSource(file))
        var keys: Set<String> = []
        var unresolved: Set<String> = []

        // 1. EVERY string-keyed dictionary literal in the file, wherever it sits.
        //
        // Anchoring on `details:` looked more precise and was in fact unsound: a payload literal
        // reaches the log through call shapes that carry no such label, and the resolver span
        // helper `beginResolverSpan(_:_:)` passes one positionally at four call sites (Codex,
        // PR #615). Chasing call shapes one at a time is how this extractor kept finding new
        // holes, so it no longer chases: a literal cannot hide from a scan that reads all of them.
        //
        // Measured, not assumed: on this tree the whole-file scan yields exactly the keys the
        // `details:`-anchored scan did and not one key more. It is bracket-matched, which is why
        // it has no false positives — the six a naive line scan collects come from misreading
        // literal boundaries, not from unrelated dictionaries.
        keys.formUnion(dictionaryLiteralKeys(in: source))

        // 2. Every payload argument that is NOT a literal, checked for provenance.
        // `details : x` is valid Swift, and an exact search for `details:` never saw it
        // (Codex, PR #615). The label and its colon are matched separately.
        var searchRange = source.startIndex..<source.endIndex
        while let label = source.range(of: "details", range: searchRange) {
            searchRange = label.upperBound..<source.endIndex
            var cursor = label.upperBound
            while cursor < source.endIndex, source[cursor].isWhitespace {
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex, source[cursor] == ":" else { continue }
            cursor = source.index(after: cursor)
            while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\n" {
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex else { break }
            unresolved.formUnion(unresolvedPayloadArgument(in: source, startingAt: cursor))
        }

        // 3. Keys added by subscript after the initializer — the half rule 1 cannot see.
        for name in assembledDetailVariables {
            keys.formUnion(subscriptKeys(in: source, forVariable: name))
        }

        // 4. Keys DERIVED from an enum rather than written as literals.
        let derived = energyCounterKeys(in: source)
        keys.formUnion(derived.keys)
        unresolved.formUnion(derived.unresolved)

        // 5. Helper bodies, and the positional `debugLogger("event", …)` transport shape.
        for helper in detailBuildingHelpers {
            keys.formUnion(helperBodyKeys(in: source, forFunction: helper))
        }
        unresolved.formUnion(unresolvedPositionalArguments(in: source))

        return (keys, unresolved)
    }

    /// The keys `BugReportBundle.allowedDetailKeys` carries.
    ///
    /// Read as SOURCE because the property is `private` — `@testable` reaches internal, not
    /// private, and widening it for a test would trade a real access boundary for a convenience.
    private static func exportAllowlist() throws -> Set<String> {
        let source = maskedForStructure(try readSource(.bugReportBundle))
        let marker = "private static let allowedDetailKeys: Set<String> = ["
        guard let start = source.range(of: marker) else {
            XCTFail("allowedDetailKeys declaration not found — update this extractor")
            return []
        }
        let openBracket = source.index(before: start.upperBound)
        guard let close = matchingBracket(in: source, openedAt: openBracket) else {
            XCTFail("allowedDetailKeys literal is unbalanced")
            return []
        }
        return quotedKeys(in: String(source[openBracket...close]), requiringColon: false)
    }

    // MARK: - Extraction primitives

    /// The identifier/member expression starting at `index`, e.g. `details`, `emission.details`,
    /// `Self.errorDebugDetails`. Stops at the first character an argument cannot continue with.
    private static func argumentExpression(in source: String, startingAt index: String.Index) -> String {
        var cursor = index
        while cursor < source.endIndex {
            let character = source[cursor]
            guard character.isLetter || character.isNumber || character == "." || character == "_"
                || character == "[" else { break }
            cursor = source.index(after: cursor)
        }
        return String(source[index..<cursor])
    }

    /// `details["key"] = …`, with the key's content unrestricted for the same reason
    /// ``quotedKeys`` no longer restricts it: a detail key is a Swift string, and requiring
    /// identifier syntax dropped `"retry-count"`-shaped keys here too (Codex, PR #615). No
    /// anchor is needed — a subscript is a key position by construction.
    private static func subscriptKeys(in source: String, forVariable name: String) -> Set<String> {
        matches(of: "\(name)\\s*\\[#*\"([^\"\\n]+)\"#*[^\\]\\n]*\\]\\s*=", in: source)
    }

    /// Keys in the body of `func <name>` — every dictionary literal it builds.
    private static func helperBodyKeys(in source: String, forFunction name: String) -> Set<String> {
        var keys: Set<String> = []
        var searchRange = source.startIndex..<source.endIndex
        while let signature = source.range(of: "func \(name)(", range: searchRange) {
            searchRange = signature.upperBound..<source.endIndex
            guard let bodyOpen = source.range(of: "{", range: signature.upperBound..<source.endIndex),
                let bodyClose = matchingBrace(in: source, openedAt: bodyOpen.lowerBound)
            else { continue }
            // Literals in the body already came from rule 1; the subscripts did not.
            let body = source[bodyOpen.lowerBound...bodyClose]
            for variable in assembledDetailVariables {
                keys.formUnion(subscriptKeys(in: String(body), forVariable: variable))
            }
        }
        return keys
    }

    /// Whether one payload argument is in a form whose keys the other passes provably cover.
    ///
    /// The SAME classification serves the labelled `details:` shape and the positional
    /// `debugLogger("event", payload)` shape, because a silent skip is a dropped diagnostic in
    /// either one — and the positional shape had a live instance of exactly that: DoQTransport
    /// logs `debugLogger("dns-doq-connection-ready", details)`, whose keys were reaching the set
    /// only by the accident of the variable being named `details` (Codex, PR #615).
    ///
    /// An argument beginning with punctuation — a parenthesised dictionary, an immediately
    /// applied closure — parses to nothing, and nothing is the one answer this must not treat as
    /// permission to continue.
    private static func unresolvedPayloadArgument(
        in source: String, startingAt cursor: String.Index
    ) -> Set<String> {
        if source[cursor] == "[" {
            guard matchingBracket(in: source, openedAt: cursor) != nil else {
                return ["unbalanced literal at \(source[cursor...].prefix(40))"]
            }
            return []
        }
        let expression = argumentExpression(in: source, startingAt: cursor)
        if expression.isEmpty {
            return ["unparseable argument: \(source[cursor...].prefix(40))"]
        }
        // A helper must be INVOKED, not merely spelled: `let errorDebugDetails = factory()` is a
        // variable that happens to share the name, and trusting the spelling marked its payload
        // traced (Codex, PR #615).
        if detailBuildingHelpers.contains(where: { expression.hasSuffix($0) }),
            isInvocation(in: source, expressionEndingAfter: cursor, length: expression.count) {
            return []
        }
        if relayedDetailArguments.contains(expression) { return [] }
        // Being NAMED `details` proves nothing on its own — the resolver span closure's parameter
        // is named that too, and the first version accepted the name as provenance (Codex,
        // PR #615). What this now asks is narrower and checkable: is the value CONSTRUCTED or
        // RECEIVED somewhere in a file this test reads? If it is, rule 1 has its literals and
        // rule 3 has its subscripts, whichever of the two shapes any individual site is. If it is
        // not, its keys may never appear as a literal here at all, and that is the case this
        // check exists to reject.
        if assembledDetailVariables.contains(expression),
            bindingIsTraced(expression, in: source, before: cursor) {
            return []
        }
        return [expression]
    }

    /// Whether the binding that produced THIS argument is one the other passes cover.
    ///
    /// Asking whether the FILE contains some `var details = [ … ]` was not enough:
    /// `PacketTunnelProvider` contains several, so every argument named `details` satisfied it —
    /// a binding written `let details = ExternalFactory.payload()`, whose keys live outside every
    /// scanned file, would have passed on the strength of an unrelated declaration elsewhere
    /// (Codex, PR #615). So look at the NEAREST binding preceding the argument, and judge that
    /// one.
    ///
    /// Two bindings qualify. A `var`/`let` initialised from a dictionary literal is covered by
    /// rule 1 for its literal and rule 3 for its subscripts. A closure or function parameter is
    /// covered because rule 1 reads the callers' literals — for callers in a scanned file. Where
    /// they live outside the set (`LatencyTrace`'s public API is reachable from the app) those
    /// sites are out of scope by construction: this test governs the TUNNEL's keys, which is what
    /// its name and its file list say.
    private static func bindingIsTraced(
        _ name: String, in source: String, before site: String.Index
    ) -> Bool {
        let head = source[source.startIndex..<site]
        let declarations = ["var \(name)", "let \(name)"]
        // The parameter forms are anchored on the punctuation that opens a parameter position.
        // Unanchored, `\(name): [String: String]` also matches inside the DECLARATION
        // `var \(name): [String: String]`, which read every uninitialised declaration as a
        // received parameter and skipped the check below entirely.
        let parameters = [", \(name) in", "(\(name): [String: String]", ", \(name): [String: String]"]

        let nearestDeclaration = nearestInScope(
            of: declarations, in: source, within: head, before: site)
        let nearestParameter = nearestInScope(
            of: parameters, in: source, within: head, before: site)

        // A parameter nearer than any declaration means the value was RECEIVED here.
        if let parameter = nearestParameter,
            nearestDeclaration.map({ parameter > $0 }) ?? true {
            return mutationsAreReadable(name, in: source, from: parameter, to: site)
        }
        guard let declaration = nearestDeclaration else { return false }
        guard initialiserIsTraced(
            in: source, declaredAt: declaration, named: name, usedAt: site)
        else { return false }
        // Mutations are checked from after the declaration STATEMENT — not after its line. The
        // declaration contains `name =`, which the whole-value-assignment check would otherwise
        // read as a replacement of the binding it establishes; but skipping to the next newline
        // skipped anything sharing the line, and `var details = […]; details.merge(…)` is valid
        // Swift (Codex, PR #615).
        let afterDeclaration = declarationEnd(in: source, at: declaration)
        guard afterDeclaration < site else { return true }
        return mutationsAreReadable(name, in: source, from: afterDeclaration, to: site)
    }

    /// A declaration is traced when it is initialised from a dictionary literal, or from one of
    /// the helpers whose body this file reads.
    private static func initialiserIsTraced(
        in source: String, declaredAt declaration: String.Index, named name: String,
        usedAt site: String.Index
    ) -> Bool {
        // The `=` must be on the declaration's own line. A declaration with no initialiser —
        // `var details: [String: String]` — is assembled afterwards; without this bound the
        // search would run on and find some later line's subscript assignment, and read an
        // untraced binding as traced.
        let lineEnd = source.range(of: "\n", range: declaration..<source.endIndex)?.lowerBound
            ?? source.endIndex
        guard let assignment = source.range(of: "=", range: declaration..<lineEnd) else {
            return isPopulatedOnlyBySubscript(name, in: source, from: declaration, to: site)
        }
        var cursor = assignment.upperBound
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\n" {
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex else { return false }
        if source[cursor] == "[" { return true }
        let initialiser = argumentExpression(in: source, startingAt: cursor)
        // Invoked, not merely spelled — the same rule the payload argument follows. Without it,
        // `let details = errorDebugDetails` aliased an untraced factory result into a traced
        // binding (Codex, PR #615).
        return detailBuildingHelpers.contains { initialiser.hasSuffix($0) }
            && isInvocation(in: source, expressionEndingAfter: cursor, length: initialiser.count)
    }

    /// Between a binding and its use, every way the payload can GAIN a key must be one the
    /// extractor reads — whatever shape the binding itself had.
    ///
    /// Two escapes, neither of which the initialiser check could see (Codex, PR #615):
    /// a computed subscript `details[key] = "1"` writes a key whose name is nowhere in the text,
    /// and `appendExternalFields(to: &details)` lets a free function add keys from an unscanned
    /// source. Both are rejected here rather than reasoned about, because a key this file cannot
    /// read is a key it cannot decide.
    private static func mutationsAreReadable(
        _ name: String, in source: String, from start: String.Index, to site: String.Index
    ) -> Bool {
        guard start < site else { return false }
        let region = String(source[start..<site])
        // A subscript whose key is not a string literal, unless it is a DECLARED derivation
        // whose keys ``energyCounterKeys`` reproduces.
        var remaining = region
        for declared in declaredDerivedSubscripts {
            remaining = remaining.replacingOccurrences(of: declared, with: "")
        }
        // A subscript opening NOT followed by a recognised key form. Checking only the first
        // character let `details["a" + suffix]` through with the wrong key extracted, and
        // `details["k", default: ""]` through with no key extracted at all (Codex, PR #615).
        if !matches(of: "(\(name)\\s*\\[(?!\(recognisedSubscriptKey)))", in: remaining).isEmpty {
            return false
        }
        // The binding handed to something else as `inout`.
        if !matches(of: "(&\(name))", in: region).isEmpty { return false }
        // Replaced wholesale, or mutated by a method. These applied only to uninitialised
        // declarations, so `var details = ["known": "1"]` followed by
        // `details.merge(ExternalFactory.payload())` passed on the strength of its opening
        // literal while the merged keys were read by nothing (Codex, PR #615).
        if !matches(of: "([^\\w.]\(name)\\s*=[^=])", in: region).isEmpty { return false }
        if !matches(of: "[^\\w.]\(name)\\.(\\w+)", in: region).isEmpty { return false }
        return true
    }

    /// An uninitialised declaration must be filled by at least one subscript assignment — the
    /// one operation rule 3 can read.
    ///
    /// "No initialiser" was accepted unconditionally, which let `var details: [String: String]`
    /// followed by `details = ExternalFactory.payload()` read as traced while no scanned text
    /// held its keys (Codex, PR #615). What a binding must NOT do afterwards is
    /// ``mutationsAreReadable``'s job, and applies to every binding rather than only this one.
    private static func isPopulatedOnlyBySubscript(
        _ name: String, in source: String, from declaration: String.Index, to site: String.Index
    ) -> Bool {
        guard declaration < site else { return false }
        let region = String(source[declaration..<site])
        let subscriptAssignment = "\(name)\\s*\\[\"[^\"\\n]+\"[^\\]\\n]*\\]\\s*="
        return !matches(of: "(\(subscriptAssignment))", in: region).isEmpty
    }

    /// The nearest occurrence of any `forms` that is still IN SCOPE at `site`.
    ///
    /// "Nearest" was textual, and Swift scope is not: an inner block's `let details = [ … ]` sits
    /// closer to a later append than the outer `let details = factory()` the append actually
    /// uses, so the extractor read the wrong binding and called the payload traced (Codex,
    /// PR #615). Walking back from the site and counting braces skips any binding whose block
    /// closed before the site.
    ///
    /// The walk is bounded. A binding further from its use than ``scopeSearchWindow`` is not one
    /// this file can reason about, and stopping there yields "unresolved" rather than "resolved
    /// by something implausibly distant" — the safe direction, and it keeps a 500 KB source from
    /// being rescanned per call site.
    private static let scopeSearchWindow = 20_000

    private static func nearestInScope(
        of forms: [String], in source: String, within head: Substring, before site: String.Index
    ) -> String.Index? {
        var candidates: Set<String.Index> = []
        for form in forms {
            var searchRange = head.startIndex..<head.endIndex
            while let hit = head.range(of: form, range: searchRange) {
                candidates.insert(hit.lowerBound)
                searchRange = hit.upperBound..<head.endIndex
            }
        }
        guard !candidates.isEmpty else { return nil }

        // Braces inside strings and comments are not scope; `maskedForStructure` has already
        // neutralised them, so this walk sees only syntactic braces.
        let start = scopeWindowStart(in: source, before: site)
        var closedBlocks = 0
        var index = site
        while index > start {
            index = source.index(before: index)
            switch source[index] {
            case "}": closedBlocks += 1
            case "{": if closedBlocks > 0 { closedBlocks -= 1 }
            default: break
            }
            // A candidate inside a block that already closed is out of scope here.
            if closedBlocks == 0, candidates.contains(index) { return index }
        }
        return nil
    }

    /// The window's start, snapped to a line boundary so the string scan below begins outside
    /// any single-line literal.
    private static func scopeWindowStart(in source: String, before site: String.Index) -> String.Index {
        let bounded = source.index(site, offsetBy: -scopeSearchWindow, limitedBy: source.startIndex)
            ?? source.startIndex
        guard let newline = source.range(of: "\n", range: bounded..<site) else { return bounded }
        return newline.upperBound
    }

    /// The source with comments blanked and structural delimiters inside string literals
    /// neutralised — SAME LENGTH, so every index still refers to the same place.
    ///
    /// Every matcher and every walk in this file counts `[`, `]`, `{` and `}`, and none of them
    /// knew whether a character was code. That produced the same defect twice in one round: a
    /// trailing `// {` cancelled a real closing brace during scope resolution, and a `"]"` inside
    /// a payload value ended the dictionary literal early so the keys after it were never
    /// extracted (Codex, PR #615). Masking once, here, is what stops the third instance.
    ///
    /// Comments go entirely, which also removes commented-out code as a source of phantom keys —
    /// `sourceExcludingComments` only ever dropped WHOLE-line comments, so a trailing one still
    /// contributed. Inside string literals only the delimiters are blanked, because the text
    /// itself is where the keys live.
    private static func maskedForStructure(_ source: String) -> String {
        var output = ""
        output.reserveCapacity(source.count)
        let characters = Array(source)
        var index = 0

        func blank(_ character: Character) -> Character { character == "\n" ? "\n" : " " }

        while index < characters.count {
            let character = characters[index]
            // Comments: blank through, preserving newlines.
            if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" {
                    output.append(" ")
                    index += 1
                }
                continue
            }
            if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                while index < characters.count {
                    let isEnd = characters[index] == "*" && index + 1 < characters.count
                        && characters[index + 1] == "/"
                    output.append(blank(characters[index]))
                    index += 1
                    if isEnd {
                        output.append(" ")
                        index += 1
                        break
                    }
                }
                continue
            }
            // Multi-line string literals: blank through, so a `"""` block cannot carry structure.
            if character == "\"", index + 2 < characters.count,
                characters[index + 1] == "\"", characters[index + 2] == "\"" {
                output.append("   ")
                index += 3
                while index < characters.count {
                    if characters[index] == "\"", index + 2 < characters.count,
                        characters[index + 1] == "\"", characters[index + 2] == "\"" {
                        output.append("   ")
                        index += 3
                        break
                    }
                    output.append(blank(characters[index]))
                    index += 1
                }
                continue
            }
            // Raw string literals: `#"…"#` ends only at a quote followed by the same run of
            // hashes, and has no escapes inside. `LatencyTrace` writes its redaction patterns
            // this way, brackets and all (Codex, PR #615).
            if character == "#" {
                var hashes = 0
                while index + hashes < characters.count, characters[index + hashes] == "#" {
                    hashes += 1
                }
                if index + hashes < characters.count, characters[index + hashes] == "\"" {
                    // Keep the delimiters and the text — a raw string can BE a key — and blank
                    // only what would otherwise read as structure.
                    output.append(String(repeating: "#", count: hashes))
                    output.append("\"")
                    index += hashes + 1
                    while index < characters.count {
                        if characters[index] == "\"" {
                            var closing = 0
                            while index + 1 + closing < characters.count,
                                characters[index + 1 + closing] == "#" {
                                closing += 1
                            }
                            if closing >= hashes {
                                output.append("\"")
                                output.append(String(repeating: "#", count: hashes))
                                index += hashes + 1
                                break
                            }
                        }
                        let inner = characters[index]
                        output.append("[](){}".contains(inner) ? " " : inner)
                        index += 1
                    }
                    continue
                }
            }
            // Single-line string literals: keep the text, neutralise the delimiters in it.
            if character == "\"" {
                output.append("\"")
                index += 1
                var isEscaped = false
                while index < characters.count {
                    let inner = characters[index]
                    if isEscaped {
                        // Blank a delimiter even when escaped: `"\\(x)"` would otherwise keep an
                        // opening paren whose closing one this loop blanks, unbalancing the file.
                        isEscaped = false
                        output.append("[](){}".contains(inner) ? " " : inner)
                    } else if inner == "\\" {
                        isEscaped = true
                        output.append(inner)
                    } else if inner == "\"" {
                        output.append("\"")
                        index += 1
                        break
                    } else if "[](){}".contains(inner) {
                        output.append(" ")
                    } else if inner == "\n" {
                        break
                    } else {
                        output.append(inner)
                    }
                    index += 1
                }
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }

    /// Keys `EnergyCounters.flush` generates from `EnergyCounter`, which are in the source but
    /// not where a literal scan looks.
    ///
    /// It emits `details[counter.rawValue]` and `details[counter.rawValue + "PerMin"]` for every
    /// case. A `String` enum's implicit raw value IS the case name, so the keys are derivable
    /// exactly rather than guessed — and they had to be, because 12 of the 18 counters and almost
    /// every per-minute variant were unexported when this was written (Codex, PR #615).
    ///
    /// This derivation is declared, not inferred: ``mutationsAreReadable`` rejects a non-literal
    /// subscript everywhere else, and the two expressions below are the only exemption. A third
    /// derived form added to that emitter fails the accounting test rather than joining this
    /// quietly.
    /// The subscript key forms this file can read: a string literal, optionally with a
    /// `default:` argument after it.
    private static let recognisedSubscriptKey = "#*\"[^\"\\n]+\"#*\\s*(?:,[^\\]\\n]*)?\\]"

    private static let declaredDerivedSubscripts = [
        "details[counter.rawValue] =",
        "details[counter.rawValue + \"PerMin\"] ="
    ]

    private static func energyCounterKeys(
        in source: String
    ) -> (keys: Set<String>, unresolved: Set<String>) {
        // The EMITTER decides whether this file owes derived keys, not the enum. Keying off the
        // enum meant a header respelled `…, CaseIterable, Sendable {` found nothing, returned no
        // keys AND no failure, and quietly dropped every counter from accounting while the
        // producer test stayed green on the file's unrelated literals (Codex, PR #615).
        let declaration = "enum EnergyCounter: String, CaseIterable {"
        let emitsDerivedKeys = declaredDerivedSubscripts.contains { source.contains($0) }
        guard let header = source.range(of: declaration),
            let bodyClose = matchingBrace(
                in: source, openedAt: source.index(before: header.upperBound))
        else {
            guard emitsDerivedKeys else { return ([], []) }
            return ([], [
                "derives detail keys from EnergyCounter, but `\(declaration)` was not found — "
                    + "the enum was respelled or moved, and its keys are now unchecked"
            ])
        }
        // SCOPED TO THE ENUM BODY. A file-wide scan for `case ` also reads every `switch` in the
        // file — including other enums' cases and `case .critical: return "critical"` — and each
        // one arrives as a phantom key demanding a decision.
        var keys: Set<String> = []
        var unresolved: Set<String> = []
        for declaration in caseDeclarations(in: String(source[header.upperBound...bodyClose])) {
            // EVERY identifier in the declaration. `case a, b` is one declaration of two cases,
            // and reading only the first omitted the second's keys without any failure to show
            // for it (Codex, PR #615).
            for element in declaration.components(separatedBy: ",") {
                let piece = element.trimmingCharacters(in: .whitespaces)
                if let name = rawValueOfCase(piece) {
                    keys.formUnion([name, name + "PerMin"])
                } else {
                    // An associated value or a computed raw value means the key is not the case
                    // name, and guessing it would be the silent drop this file exists to stop.
                    unresolved.insert("unsupported EnergyCounter case: \(piece)")
                }
            }
        }
        return (keys, unresolved)
    }

    /// Case declarations in an enum body, each joined back into one string.
    ///
    /// Swift lets a declaration wrap: `case existing,\n newCounter` and `case renamed\n = "lit"`
    /// are both valid, and reading line by line dropped the second case in the first shape and
    /// mistook the case name for the raw value in the second (Codex, PR #615). Continuations are
    /// joined on the punctuation that can end or begin one, so the parser downstream sees whole
    /// declarations; anything it still cannot read fails closed there.
    private static func caseDeclarations(in body: String) -> [String] {
        var declarations: [String] = []
        var current: String?
        for rawLine in body.components(separatedBy: "\n") {
            let line = rawLine.components(separatedBy: "//")[0]
                .trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            // `case` alone on its line is a valid declaration awaiting its identifiers, and a
            // prefix check for "case " skipped it — then skipped the identifiers too, because
            // no declaration was open to attach them to (Codex, PR #615).
            if line == "case" || line.hasPrefix("case ") {
                if let open = current { declarations.append(open) }
                current = String(line.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard let open = current else { continue }
            // An EMPTY declaration is still owed its identifiers, so the next line continues it
            // whatever punctuation it starts with.
            let continues = open.isEmpty || open.hasSuffix(",") || open.hasSuffix("=")
                || line.hasPrefix(",") || line.hasPrefix("=")
            if continues {
                current = open.isEmpty ? line : open + " " + line
            } else {
                declarations.append(open)
                current = nil
            }
        }
        if let open = current { declarations.append(open) }
        return declarations
    }

    private static func isInvocation(
        in source: String, expressionEndingAfter cursor: String.Index, length: Int
    ) -> Bool {
        guard let end = source.index(cursor, offsetBy: length, limitedBy: source.endIndex),
            end < source.endIndex
        else { return false }
        return source[end] == "("
    }

    /// The raw value a `String` enum case carries: its explicit literal, else its own name.
    private static func rawValueOfCase(_ piece: String) -> String? {
        if piece.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }), !piece.isEmpty {
            return piece
        }
        let explicit = matches(of: "^\\w+\\s*=\\s*\"([^\"]+)\"$", in: piece)
        return explicit.count == 1 ? explicit.first : nil
    }

    /// Every string-keyed dictionary literal in the file, bracket-matched.
    private static func dictionaryLiteralKeys(in source: String) -> Set<String> {
        var keys: Set<String> = []
        var index = source.startIndex
        while let open = source.range(of: "[", range: index..<source.endIndex) {
            guard let close = matchingBracket(in: source, openedAt: open.lowerBound) else { break }
            keys.formUnion(quotedKeys(in: String(source[open.lowerBound...close])))
            index = source.index(after: close)
        }
        return keys
    }

    /// Calls that pass a payload POSITIONALLY, after a string event or span name.
    ///
    /// `debugLogger("dns-doh-connection-ready", [ … ])` in the transports, and any local closure
    /// declared to take a `[String: String]`. The payload is classified exactly like a labelled
    /// one: reading only calls that happen to contain a `[` would skip
    /// `debugLogger("event", makeDetails())` silently while
    /// ``testEveryRelayProducerStillYieldsKeys`` stayed green on the file's other calls.
    private static func unresolvedPositionalArguments(in source: String) -> Set<String> {
        var unresolved: Set<String> = []
        for callee in ["debugLogger"] + payloadTakingClosureNames(in: source) {
            unresolved.formUnion(unresolvedPositionalArguments(in: source, calling: callee))
        }
        return unresolved
    }

    /// Local closures that TAKE a payload positionally, found by their declared function type.
    ///
    /// `beginResolverSpan` is declared `@Sendable (String, [String: String]) -> LatencySpan` and
    /// called `beginResolverSpan("resolver.endpointAttempt", ["transport": "DoH"])`. Today every
    /// caller passes a literal, which rule 1 reads — but a caller passing a variable would have
    /// been inspected by nothing, because only `debugLogger` had its positional calls classified
    /// (Codex, PR #615). Any closure with a `[String: String]` parameter now gets the same
    /// treatment, so the shape is covered rather than this one instance of it.
    private static func payloadTakingClosureNames(in source: String) -> [String] {
        matches(of: "let (\\w+): [^=\\n]*\\[String: String\\]\\) ->", in: source).sorted()
    }

    private static func unresolvedPositionalArguments(
        in source: String, calling callee: String
    ) -> Set<String> {
        var unresolved: Set<String> = []
        var searchRange = source.startIndex..<source.endIndex
        while let call = source.range(of: "\(callee)(", range: searchRange) {
            searchRange = call.upperBound..<source.endIndex
            // The event name is a string literal; the payload is whatever follows its comma.
            guard let nameOpen = source.range(of: "\"", range: call.upperBound..<source.endIndex),
                source[call.upperBound..<nameOpen.lowerBound]
                    .allSatisfy({ $0 == " " || $0 == "\n" }),
                let nameClose = source.range(of: "\"", range: nameOpen.upperBound..<source.endIndex),
                let comma = source.range(of: ",", range: nameClose.upperBound..<source.endIndex),
                source[nameClose.upperBound..<comma.lowerBound]
                    .allSatisfy({ $0 == " " || $0 == "\n" })
            else {
                unresolved.insert(
                    "\(callee) call with no string event name: "
                        + "\(source[call.upperBound...].prefix(40))")
                continue
            }
            var cursor = comma.upperBound
            while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\n" {
                cursor = source.index(after: cursor)
            }
            guard cursor < source.endIndex else { break }
            unresolved.formUnion(unresolvedPayloadArgument(in: source, startingAt: cursor))
        }
        return unresolved
    }

    /// Just past a declaration's own statement: its initialiser expression, or its type
    /// annotation when it has none.
    private static func declarationEnd(in source: String, at declaration: String.Index) -> String.Index {
        let lineEnd = source.range(of: "\n", range: declaration..<source.endIndex)?.lowerBound
            ?? source.endIndex
        guard let assignment = source.range(of: "=", range: declaration..<lineEnd) else {
            // No initialiser: the statement ends at the type annotation.
            if let open = source.range(of: "[", range: declaration..<lineEnd),
                let close = matchingBracket(in: source, openedAt: open.lowerBound) {
                return source.index(after: close)
            }
            return lineEnd
        }
        var cursor = assignment.upperBound
        while cursor < source.endIndex, source[cursor] == " " || source[cursor] == "\n" {
            cursor = source.index(after: cursor)
        }
        guard cursor < source.endIndex else { return cursor }
        if source[cursor] == "[", let close = matchingBracket(in: source, openedAt: cursor) {
            return source.index(after: close)
        }
        let expression = argumentExpression(in: source, startingAt: cursor)
        var end = source.index(cursor, offsetBy: expression.count, limitedBy: source.endIndex)
            ?? source.endIndex
        if end < source.endIndex, source[end] == "(",
            let close = matchingParenthesis(in: source, openedAt: end) {
            end = source.index(after: close)
        }
        return end
    }

    private static func matchingParenthesis(
        in source: String, openedAt open: String.Index
    ) -> String.Index? {
        matchingDelimiter(in: source, openedAt: open, open: "(", close: ")")
    }

    private static func matchingBracket(in source: String, openedAt open: String.Index) -> String.Index? {
        matchingDelimiter(in: source, openedAt: open, open: "[", close: "]")
    }

    private static func matchingBrace(in source: String, openedAt open: String.Index) -> String.Index? {
        matchingDelimiter(in: source, openedAt: open, open: "{", close: "}")
    }

    private static func matchingDelimiter(
        in source: String, openedAt start: String.Index, open: Character, close: Character
    ) -> String.Index? {
        var depth = 0
        var index = start
        while index < source.endIndex {
            if source[index] == open { depth += 1 }
            if source[index] == close {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Dictionary keys in a literal (`"name":`), or every string in a set literal.
    ///
    /// A key is matched only where a key can appear — directly after the opening `[` or a comma.
    /// That is not decoration: without the anchor, `enabled ? "missing" : "fail-closed"` inside a
    /// payload reads as a key called `missing`, and the freeze list carried exactly that phantom
    /// until the anchor removed it.
    ///
    /// The key's CONTENT is unrestricted, because a detail key is a Swift string and nothing
    /// requires it to be identifier-shaped. Matching `[A-Za-z][A-Za-z0-9_]*` quietly dropped any
    /// `"retry-count"`-style key, which then never entered the emitted set and could go
    /// unexported with this whole file still green (Codex, PR #615).
    private static func quotedKeys(in block: String, requiringColon: Bool = true) -> Set<String> {
        guard requiringColon else { return matches(of: "#*\"([^\"\\n]+)\"#*", in: block) }
        var keys = matches(of: "[\\[,]\\s*\"([^\"\\n]+)\"\\s*:", in: block)
        // A raw string closes only on a quote followed by ITS hash run, so its text may contain
        // quotes: `#"retry"count"#` is one key, and a pattern that stops at any quote read none
        // (Codex, PR #615). The backreference ties the closer to the opener.
        keys.formUnion(
            matches(
                of: "[\\[,]\\s*(#+)\"((?:(?!\"\\1).)*)\"\\1\\s*:", in: block, group: 2))
        return keys
    }

    private static func matches(
        of pattern: String, in block: String, group: Int = 1
    ) -> Set<String> {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])
        else { return [] }
        let text = block as NSString
        return Set(
            regex.matches(in: block, range: NSRange(location: 0, length: text.length))
                .compactMap { match in
                    let range = match.range(at: group)
                    return range.location == NSNotFound ? nil : text.substring(with: range)
                })
    }
}
