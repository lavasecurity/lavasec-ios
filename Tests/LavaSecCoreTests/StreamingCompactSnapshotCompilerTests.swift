import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

/// Covers the in-extension streaming compile (`StreamingCompactSnapshotCompiler` via the
/// `CachedFilterSnapshotCompiler` facade) and the shared on-disk writer
/// (`CompactFilterSnapshot.writeStreaming`): byte-format parity with the in-heap encoder,
/// the `readSummary` cross-check on streamed bytes, end-to-end equivalence with an in-heap
/// union reference, and scratch cleanup.
final class StreamingCompactSnapshotCompilerTests: XCTestCase {

    func testAllowedSuffixIndexMatchesAncestorAndDescendantOverlap() {
        let allowed = ["example.com", "child.example.com", "deep.child.example.com",
                       "other.com", "notexample.com", "child.example.com"]
        let index = AllowedSuffixIntersectionIndex(normalizedDomains: allowed)
        for threat in ["example.com", "evil.example.com", "child.example.com",
                       "com", "other.com", "notexample.com", "ample.com"] {
            let expectedAncestor = allowed.contains { threat == $0 || threat.hasSuffix("." + $0) }
            XCTAssertEqual(index.containsAncestor(of: threat), expectedAncestor, threat)
            var descendants: Set<String> = []
            index.forEachDescendant(of: threat) { descendants.insert($0) }
            let expectedDescendants = Set(allowed.filter { $0.hasSuffix("." + threat) })
            XCTAssertEqual(descendants, expectedDescendants, threat)
        }
    }

    // MARK: writeStreaming — byte-format single source of truth

    func testBroadAllowedSuffixCannotPublishAnOverBudgetHeapGuardrailSet() async throws {
        try await withTemporaryDirectory { cacheURL in
            let configuration = AppConfiguration(enabledBlocklistIDs: [], allowedDomains: ["example.com"])
            let retained = cacheURL.appendingPathComponent("retained.lscfsnp")
            let compiler = CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
            try writeGuardrailCatalog("before.example.com\n", to: cacheURL)
            _ = try await compiler.compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration,
                                           retainedArtifactURL: retained)
            let previousArtifact = try Data(contentsOf: retained)

            // Each valid descendant is distinct: one broad allowance must not admit
            // an unbounded heap-backed threat set before compact encoding begins.
            let text = (0..<4_097).map { "threat\($0).example.com\n" }.joined()
            try writeGuardrailCatalog(text, to: cacheURL)
            do {
                _ = try await compiler.compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration,
                                               retainedArtifactURL: retained)
                XCTFail("Expected the streamed descendant guardrail heap budget to fail closed")
            } catch {
                XCTAssertTrue(error.localizedDescription.lowercased().contains("guardrail"))
            }
            XCTAssertEqual(try Data(contentsOf: retained), previousArtifact,
                           "A failed compile must not replace the last complete retained artifact")
            let scratch = StreamingCompactSnapshotCompiler.scratchRootURL(cacheDirectoryURL: cacheURL)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        }
    }

    private func writeGuardrailCatalog(_ text: String, to cacheURL: URL) throws {
        let source = makeSource(id: "guardrail-budget-source", sourceHash: hash(text))
        let catalog = BlocklistCatalog(schemaVersion: 2, catalogVersion: "20260101T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000), sources: [], guardrails: [source])
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(text, sourceID: source.id, to: cacheURL)
    }

    func testGuardrailBudgetAcceptsItsBoundaryAndChargesOverlappingScopesOnce() async throws {
        try await withTemporaryDirectory { cacheURL in
            let limit = FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount
            let configuration = AppConfiguration(enabledBlocklistIDs: [],
                allowedDomains: ["example.com", "nested.example.com"])
            let lines = (0..<limit).map { "threat\($0).nested.example.com\n" }.joined()
            try writeGuardrailCatalog(lines + lines, to: cacheURL)
            let base = configuration.filterSnapshot(nonAllowableThreatRules:
                DomainRuleSet(suffixDomains: ["threat0.nested.example.com"]))
            let compiled = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                .compile(baseSnapshot: base, configuration: configuration)
            XCTAssertEqual(compiled.guardrailRuleCount, limit,
                           "Duplicate lines, overlapping allowances and the base duplicate each retain one scope")
            let cold = try CompactFilterSnapshot.decode(from: compiled.encodedData())
            XCTAssertEqual(cold.guardrailRuleCount, limit)
            XCTAssertEqual(cold.decision(for: "threat0.nested.example.com").reason, .threatGuardrail)
            XCTAssertEqual(cold.decision(for: "sub.threat\(limit - 1).nested.example.com").reason, .threatGuardrail)
            XCTAssertEqual(cold.decision(for: "safe.nested.example.com").reason, .localAllowlist)
            XCTAssertEqual(cold.effectiveAllowRuleCount, 2)
            XCTAssertEqual(cold.allowedSuffixGuardrailCoverage, compiled.allowedSuffixGuardrailCoverage)
        }
    }

    func testBaseThreatMergeCannotBypassTheHeapBoundOrCollapseExactAndSuffixKinds() async throws {
        try await withTemporaryDirectory { cacheURL in
            let limit = FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount
            let configuration = AppConfiguration(enabledBlocklistIDs: [], allowedDomains: ["example.com"])
            try writeGuardrailCatalog((0..<limit).map { "threat\($0).example.com\n" }.joined(), to: cacheURL)
            // A byte-equal exact entry is still a separate resident entry from its suffix.
            let base = configuration.filterSnapshot(nonAllowableThreatRules:
                DomainRuleSet(exactDomains: ["threat0.example.com"]))
            do {
                _ = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                    .compile(baseSnapshot: base, configuration: configuration)
                XCTFail("Expected the base contribution to use the same heap bound")
            } catch let error as StreamingCompileGuardrailBudgetExceeded {
                XCTAssertEqual(error.ruleCount, limit + 1)
            }
            let scratch = StreamingCompactSnapshotCompiler.scratchRootURL(cacheDirectoryURL: cacheURL)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        }
    }

    func testOversizedBaseThreatSetIsRejectedBeforeScratchAllocation() async throws {
        try await withTemporaryDirectory { cacheURL in
            let limit = FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount
            let configuration = AppConfiguration(enabledBlocklistIDs: [])
            let base = FilterSnapshot(blockRules: DomainRuleSet(), nonAllowableThreatRules: DomainRuleSet(
                suffixDomains: Set((0...limit).map { "threat\($0).example.com" })))
            do {
                _ = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                    .compile(baseSnapshot: base, configuration: configuration)
                XCTFail("Expected the oversized base to fail before loading or allocating scratch")
            } catch let error as StreamingCompileGuardrailBudgetExceeded {
                XCTAssertEqual(error.ruleCount, limit + 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath:
                StreamingCompactSnapshotCompiler.scratchRootURL(cacheDirectoryURL: cacheURL).path))
        }
    }

    func testRetainedGuardrailsAlsoConsumeTheStreamingAggregateBudget() async throws {
        try await withTemporaryDirectory { cacheURL in
            let limit = FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount
            // Repeated block emissions still occupy compact entries before deduplication.
            // This exercises the actual production ceiling without millions of heap strings.
            let blocks = String(repeating: "b.test\n", count: limit)
            let blockSource = makeSource(id: "aggregate-block-source", sourceHash: hash(blocks))
            let threats = "evil.example.com\n"
            let threatSource = makeSource(id: "aggregate-threat-source", sourceHash: hash(threats))
            let catalog = BlocklistCatalog(schemaVersion: 2, catalogVersion: "20260101T000000Z",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000), sources: [blockSource], guardrails: [threatSource])
            try writeCatalog(catalog, to: cacheURL)
            try writeLatestBlocklist(blocks, sourceID: blockSource.id, to: cacheURL)
            try writeLatestBlocklist(threats, sourceID: threatSource.id, to: cacheURL)
            let configuration = AppConfiguration(enabledBlocklistIDs: [blockSource.id], allowedDomains: ["example.com"])
            let retained = cacheURL.appendingPathComponent("must-not-publish.lscfsnp")
            do {
                _ = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                    .compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration,
                             retainedArtifactURL: retained)
                XCTFail("Expected the first unique guardrail beyond the aggregate ceiling to fail")
            } catch let error as StreamingCompileBudgetExceeded {
                XCTAssertEqual(error.ruleCount, limit + 1)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: retained.path))
            let scratch = StreamingCompactSnapshotCompiler.scratchRootURL(cacheDirectoryURL: cacheURL)
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: scratch.path).isEmpty)
        }
    }

    /// `writeStreaming` must emit bytes identical to the in-heap `encodedData()` when given
    /// the same (sorted) tables, and the result must pass the strict `decode` and the cheap
    /// `readSummary` cross-check. Also locks the no-cross-dedup invariant: a domain present
    /// as BOTH an exact and a suffix rule stays in both tables.
    func testWriteStreamingMatchesInHeapEncoderAndPassesReaders() throws {
        try withTemporaryDirectory { dir in
            let exactDomains = ["a.example.com", "x.example.com"]
            let suffixDomains = ["x.example.com", "z.example.com"] // x.example.com in both tables

            // Build the blob + entries exactly as `CompactDomainRuleTableBuilder` does (exact
            // sorted, then suffix sorted, into one contiguous blob with monotonic offsets):
            // each domain is stored as a 1-byte length prefix followed by its bytes, and the
            // entry is the byte offset of that prefix.
            var blob = Data()
            var exactEntries: [CompactDomainRuleSet.Entry] = []
            for domain in exactDomains {
                let bytes = Data(domain.utf8)
                exactEntries.append(UInt32(blob.count))
                blob.append(UInt8(bytes.count))
                blob.append(bytes)
            }
            var suffixEntries: [CompactDomainRuleSet.Entry] = []
            for domain in suffixDomains {
                let bytes = Data(domain.utf8)
                suffixEntries.append(UInt32(blob.count))
                blob.append(UInt8(bytes.count))
                blob.append(bytes)
            }

            let identity = PreparedFilterSnapshotIdentity.make(
                configuration: AppConfiguration(enabledBlocklistIDs: []),
                catalog: nil
            )
            let generatedAt = Date(timeIntervalSince1970: 1_700_000_000)
            let reference = CompactFilterSnapshot(
                identity: identity,
                generatedAt: generatedAt,
                resolver: .google,
                blockRules: CompactDomainRuleSet(exactDomains: exactDomains, suffixDomains: suffixDomains),
                allowRules: CompactDomainRuleSet(),
                nonAllowableThreatRules: CompactDomainRuleSet()
            )
            let referenceBytes = try reference.encodedData()

            let blobURL = dir.appendingPathComponent("blob")
            try blob.write(to: blobURL)
            let outURL = dir.appendingPathComponent("snapshot")
            XCTAssertTrue(FileManager.default.createFile(atPath: outURL.path, contents: nil))
            let handle = try FileHandle(forWritingTo: outURL)

            try CompactFilterSnapshot.writeStreaming(
                to: handle,
                identity: identity,
                generatedAt: generatedAt,
                resolver: .google,
                // Use the reference's recomputed summary so the metadata region matches too.
                summary: reference.summary,
                blockExactEntries: exactEntries,
                blockSuffixEntries: suffixEntries,
                blockDomainDataURL: blobURL,
                blockDomainDataCount: blob.count,
                allowRules: CompactDomainRuleSet(),
                nonAllowableThreatRules: CompactDomainRuleSet()
            )
            try handle.close()

            let streamedBytes = try Data(contentsOf: outURL)
            // The RULE-TABLE region (what `writeStreaming` lays out via the shared
            // `emitTablePrefix` + blob) must be byte-identical to the in-heap encoder — this
            // locks the format SSOT. We do NOT compare the metadata region: `DNSResolverPreset`
            // (and dict/Date) JSON key order is not guaranteed stable across encoder calls, so a
            // raw whole-file compare is flaky; metadata correctness is covered by `readSummary` +
            // `decode` below (which round-trip regardless of key order).
            XCTAssertEqual(
                Self.ruleTableRegion(of: streamedBytes),
                Self.ruleTableRegion(of: referenceBytes),
                "Streamed rule-table bytes must match the in-heap encoder byte-for-byte."
            )

            // Cheap header cross-check (block/allow/guardrail counts vs tables) must pass.
            let summary = try CompactFilterSnapshot.readSummary(from: streamedBytes)
            XCTAssertEqual(summary.blockRuleCount, 4)
            XCTAssertEqual(summary.allowRuleCount, 0)
            XCTAssertEqual(summary.guardrailRuleCount, 0)

            // Full decode + decisions: exact and suffix x.example.com both retained.
            let decoded = try CompactFilterSnapshot.decode(from: streamedBytes)
            XCTAssertEqual(decoded.blockRuleCount, 4)
            XCTAssertEqual(decoded.decision(for: "a.example.com").reason, .blocklist)
            XCTAssertEqual(decoded.decision(for: "sub.a.example.com").reason, .defaultAllow) // exact only
            XCTAssertEqual(decoded.decision(for: "x.example.com").reason, .blocklist)
            XCTAssertEqual(decoded.decision(for: "sub.x.example.com").reason, .blocklist)   // suffix match
            XCTAssertEqual(decoded.decision(for: "sub.z.example.com").reason, .blocklist)   // suffix match
            XCTAssertEqual(decoded.decision(for: "unrelated.test").reason, .defaultAllow)
        }
    }

    // MARK: End-to-end compiler — equivalence with an in-heap union reference

    /// Compiling two sources that share a domain (plus a manual block rule) must produce the
    /// same deduped block count and the same decisions as an in-heap union of the same
    /// sources — proving cross-source dedup and the full streaming pipeline.
    func testStreamingCompileDedupesAcrossSourcesAndMatchesUnionReference() async throws {
        try await withTemporaryDirectory { cacheURL in
            let textA = "ads.example.com\nshared.example.com\n"
            let textB = "shared.example.com\ntrackers.example.net\n"
            let sourceA = makeSource(id: "source-a", sourceHash: hash(textA))
            let sourceB = makeSource(id: "source-b", sourceHash: hash(textB))
            let catalog = makeCatalog(sources: [sourceA, sourceB])

            try writeCatalog(catalog, to: cacheURL)
            try writeLatestBlocklist(textA, sourceID: sourceA.id, to: cacheURL)
            try writeLatestBlocklist(textB, sourceID: sourceB.id, to: cacheURL)

            let configuration = AppConfiguration(
                enabledBlocklistIDs: [sourceA.id, sourceB.id],
                blockedDomains: ["manual.example.org"]
            )

            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: false
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            // Reference: union the same parsed sources in heap with the APP's real budget
            // (.default, the 2M Plus cap) — NOT .inExtension — so this would catch any
            // per-source truncation/coverage divergence the in-extension compile introduced.
            let synchronizer = BlocklistCatalogSynchronizer(cacheDirectoryURL: cacheURL, parseBudget: .default)
            let result = try await synchronizer.loadCached(
                enabledSourceIDs: configuration.enabledBlocklistIDs,
                includesGuardrails: false
            )
            var union = DomainRuleSet()
            for id in configuration.enabledBlocklistIDs {
                if let rs = result.sourceRuleSets[id] { union.formUnion(rs) }
            }
            union.formUnion(configuration.manualBlockRuleSet)
            let reference = CompactDomainRuleSet(ruleSet: union)

            // shared.example.com deduped: ads, shared, trackers, manual = 4 unique block rules.
            XCTAssertEqual(compiled.blockRuleCount, reference.count)
            XCTAssertEqual(compiled.blockRuleCount, 4)

            // INV-TIER-1 (PR #335 Codex P1 + P2): the in-extension compile stamps its recorded
            // tier total as the cold gate's exact block part — deduped tables + |manual∩lists|
            // (+ allow + threat subset). Here manual.example.org appears in NO list: tables = 4,
            // overlap = 0, so the stamp equals blockRuleCount and must NOT re-add the disjoint
            // manual rule (over-recording would fail-close a near-cap filter the cold gate
            // passed). The tunnel serve gates bind this value and fail closed on nil, so an
            // unstamped retained artifact would be unloadable on the next cold start.
            XCTAssertEqual(compiled.summary.tierBudgetRuleCount, 4)
            XCTAssertEqual(compiled.summary.tierBudgetRuleCount, compiled.blockRuleCount)

            for domain in ["ads.example.com", "shared.example.com", "trackers.example.net", "manual.example.org"] {
                XCTAssertEqual(compiled.decision(for: domain).reason, .blocklist, "\(domain) should be blocked")
            }
            XCTAssertEqual(compiled.decision(for: "not-blocked.example.com").reason, .defaultAllow)
            XCTAssertEqual(compiled.resolver, configuration.resolverPreset)
        }
    }

    /// INV-TIER-1 (PR #335 Codex P2 round 4): a manual blocked domain that a LIST also
    /// carries dedupes INTO the table (blockRuleCount unchanged) but the cold gate counts
    /// it separately (list-merge excludes manual + blockedDomains.count), so the stamp
    /// must re-add the overlap — without it, a free config at exactly 500,000 list rules
    /// plus one already-listed manual domain records 500,000 here while the cold gate
    /// computes 500,001 and rejects: the tunnel would serve what the app refuses.
    func testTierStampReAddsManualDomainsThatListsAlreadyCarry() async throws {
        try await withTemporaryDirectory { cacheURL in
            let textA = "ads.example.com\nshared.example.com\n"
            let textB = "shared.example.com\ntrackers.example.net\n"
            let sourceA = makeSource(id: "source-a", sourceHash: hash(textA))
            let sourceB = makeSource(id: "source-b", sourceHash: hash(textB))
            let catalog = makeCatalog(sources: [sourceA, sourceB])

            try writeCatalog(catalog, to: cacheURL)
            try writeLatestBlocklist(textA, sourceID: sourceA.id, to: cacheURL)
            try writeLatestBlocklist(textB, sourceID: sourceB.id, to: cacheURL)

            let configuration = AppConfiguration(
                enabledBlocklistIDs: [sourceA.id, sourceB.id],
                // One manual domain the lists ALREADY carry, one they don't.
                blockedDomains: ["shared.example.com", "manual.example.org"]
            )

            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: false
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            // Tables: ads, shared, trackers, manual = 4 (shared collapsed with the manual copy).
            XCTAssertEqual(compiled.blockRuleCount, 4)
            // Stamp: tables (4) + overlap (shared.example.com = 1) — the cold formula's
            // list-merge (3) + blockedDomains (2).
            XCTAssertEqual(compiled.summary.tierBudgetRuleCount, 5)
        }
    }

    /// A single source far larger than the old per-source cap (~183K) compiles in FULL —
    /// the streaming parse never builds a per-source Set, so it is bounded only by the
    /// aggregate, NOT silently truncated. (This is the regression the streaming-parse fix
    /// closes: before it, a >183K source was truncated and served under the full identity.)
    func testLargeSourceCompilesInFullWithoutTruncation() async throws {
        try await withTemporaryDirectory { cacheURL in
            let ruleCount = 200_000 // > the former ~183,500 in-extension per-source cap
            var lines = ""
            lines.reserveCapacity(ruleCount * 22)
            for index in 0..<ruleCount {
                lines += "d\(index).example.com\n"
            }
            let source = makeSource(id: "big-source", sourceHash: hash(lines))
            try writeCatalog(makeCatalog(sources: [source]), to: cacheURL)
            try writeLatestBlocklist(lines, sourceID: source.id, to: cacheURL)

            let configuration = AppConfiguration(enabledBlocklistIDs: [source.id])
            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: false
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            XCTAssertEqual(compiled.blockRuleCount, ruleCount, "all 200K rules must survive (no truncation)")
            XCTAssertEqual(compiled.decision(for: "d0.example.com").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "d199999.example.com").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "d200000.example.com").reason, .defaultAllow)
        }
    }

    // 1Hosts Xtra — the largest single list a user realistically adds — is 663,491 rules /
    // 12.2 MB in adblock form (per the list's own header, 2026-06-21). This proves an
    // Xtra-sized single source streams through the in-extension compile IN FULL: no
    // truncation, no per-source dirty `Set`, comfortably under the streaming ceiling, and
    // with the served snapshot well under the device memory budget. 700K brackets Xtra with
    // margin, and ~14 MB of raw payload also exercises the 25 MB in-extension intake cap.
    func testXtraSizedSingleSourceCompilesInFullInExtension() async throws {
        try await withTemporaryDirectory { cacheURL in
            let ruleCount = 700_000 // brackets 1Hosts Xtra (663,491 rules)
            XCTAssertLessThan(
                ruleCount,
                FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount,
                "an Xtra-sized source must sit well under the in-extension streaming ceiling"
            )
            var lines = ""
            lines.reserveCapacity(ruleCount * 22)
            for index in 0..<ruleCount {
                lines += "d\(index).example.com\n"
            }
            let source = makeSource(id: "xtra-sized-source", sourceHash: hash(lines))
            try writeCatalog(makeCatalog(sources: [source]), to: cacheURL)
            try writeLatestBlocklist(lines, sourceID: source.id, to: cacheURL)

            let configuration = AppConfiguration(enabledBlocklistIDs: [source.id])
            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: false
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            XCTAssertEqual(compiled.blockRuleCount, ruleCount, "all Xtra-sized rules must survive (no truncation)")
            XCTAssertEqual(compiled.decision(for: "d0.example.com").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "d699999.example.com").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "d700000.example.com").reason, .defaultAllow)
            // The served, mapped-compact snapshot (~5 B/rule) stays within the device budget.
            XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiled.blockRuleCount))
        }
    }

    /// Guardrails intersected with the allowlist: an allowed domain that a guardrail source
    /// blocks becomes a non-allowable threat rule (and the guardrail union is never resident).
    func testGuardrailIntersectionWithAllowlist() async throws {
        try await withTemporaryDirectory { cacheURL in
            let blockText = "ads.example.com\n"
            let guardrailText = "evil.example.com\nbad.example.com\n" // descendant suffix rules
            let blockSource = makeSource(id: "block-src", sourceHash: hash(blockText))
            let guardrailSource = makeSource(id: "guard-src", sourceHash: hash(guardrailText))
            let catalog = BlocklistCatalog(
                schemaVersion: 2,
                catalogVersion: "20260101T000000Z",
                generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
                sources: [blockSource],
                guardrails: [guardrailSource]
            )
            try writeCatalog(catalog, to: cacheURL)
            try writeLatestBlocklist(blockText, sourceID: blockSource.id, to: cacheURL)
            try writeLatestBlocklist(guardrailText, sourceID: guardrailSource.id, to: cacheURL)

            // sub.evil.example.com is allowlisted but the guardrail blocks evil.example.com (suffix),
            // so it must stay blocked as a threatGuardrail (the allow can't override the guardrail).
            let configuration = AppConfiguration(
                enabledBlocklistIDs: [blockSource.id],
                allowedDomains: ["example.com"]
            )
            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: true
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            XCTAssertEqual(compiled.decision(for: "sub.evil.example.com").reason, .threatGuardrail)
            XCTAssertEqual(compiled.decision(for: "safe.example.com").reason, .localAllowlist)
            XCTAssertEqual(compiled.decision(for: "evil.example.com").reason, .threatGuardrail)
            XCTAssertEqual(compiled.decision(for: "ads.example.com").reason, .localAllowlist)
            let adopted = FilterLooseningReapplyPolicy.RuleCounts(snapshot: compiled)
            XCTAssertEqual(compiled.guardrailRuleCount, 2)
            let regular = configuration.filterSnapshot(nonAllowableThreatRules:
                DomainRuleSet(suffixDomains: ["evil.example.com", "bad.example.com"]))
            XCTAssertEqual(adopted.effectiveAllowRuleCount, regular.effectiveAllowRuleCount)
            let decoded = try CompactFilterSnapshot.decode(from: compiled.encodedData())
            XCTAssertEqual(decoded.effectiveAllowRuleCount, regular.effectiveAllowRuleCount)
            XCTAssertEqual(adopted.effectiveAllowRuleCount, 1,
                           "A descendant threat cannot erase the broader parent allowance")
            XCTAssertTrue(FilterLooseningReapplyPolicy.isLoosening(
                previous: .init(blockRuleCount: compiled.blockRuleCount, allowRuleCount: 0, guardrailRuleCount: 0),
                adopted: adopted))

            // The next streamed catalog releases the descendant threats while keeping
            // the same allow and ordinary block tables. Cold decoding preserves the signal.
            try writeCatalog(makeCatalog(sources: [blockSource]), to: cacheURL)
            let released = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL, includesGuardrails: true
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)
            let coldReleased = try CompactFilterSnapshot.decode(from: released.encodedData())
            XCTAssertEqual(released.decision(for: "sub.evil.example.com").reason, .localAllowlist)
            XCTAssertEqual(released.blockRuleCount, compiled.blockRuleCount)
            XCTAssertEqual(released.effectiveAllowRuleCount, compiled.effectiveAllowRuleCount)
            XCTAssertNotEqual(adopted.allowedSuffixGuardrailCoverage["example.com"], GuardrailScopeCoverage())
            XCTAssertEqual(coldReleased.allowedSuffixGuardrailCoverage, ["example.com": GuardrailScopeCoverage()])
            XCTAssertTrue(FilterLooseningReapplyPolicy.isLoosening(
                previous: adopted, adopted: .init(snapshot: coldReleased)))
        }
    }

    /// An enabled-but-empty config with only manual block rules still compiles to a valid
    /// mapped snapshot blocking the manual domains.
    func testStreamingCompileWithManualBlockRulesOnly() async throws {
        try await withTemporaryDirectory { cacheURL in
            try writeCatalog(makeCatalog(sources: []), to: cacheURL)

            let configuration = AppConfiguration(
                enabledBlocklistIDs: [],
                blockedDomains: ["manual-one.example.org", "manual-two.example.org"]
            )

            let compiled = try await CachedFilterSnapshotCompiler(
                cacheDirectoryURL: cacheURL,
                includesGuardrails: false
            ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

            XCTAssertEqual(compiled.blockRuleCount, 2)
            XCTAssertEqual(compiled.decision(for: "manual-one.example.org").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "sub.manual-two.example.org").reason, .blocklist)
            XCTAssertEqual(compiled.decision(for: "elsewhere.example.com").reason, .defaultAllow)
        }
    }

    /// An enabled source with no catalog or custom entry must fail explicitly (fail-closed),
    /// same as the app's gate.
    func testStreamingCompileFailsForEnabledIDWithoutSource() async throws {
        try await withTemporaryDirectory { cacheURL in
            try writeCatalog(makeCatalog(sources: []), to: cacheURL)

            let configuration = AppConfiguration(enabledBlocklistIDs: ["missing-source"])
            do {
                _ = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                    .compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)
                XCTFail("Expected missingEnabledBlocklistSource")
            } catch BlocklistCatalogSyncError.missingEnabledBlocklistSource(let sourceID) {
                XCTAssertEqual(sourceID, "missing-source")
            }
        }
    }

    // MARK: Cleanup

    /// A successful compile leaves no scratch behind (it maps the artifact then removes the
    /// per-compile dir; the mapping survives via inode pinning), and `sweepStaleScratch`
    /// removes any orphan a jetsam-killed compile would leave.
    func testCompileCleansScratchAndSweepRemovesOrphans() async throws {
        try await withTemporaryDirectory { cacheURL in
            try writeCatalog(makeCatalog(sources: []), to: cacheURL)

            let configuration = AppConfiguration(enabledBlocklistIDs: [], blockedDomains: ["m.example.org"])
            let compiled = try await CachedFilterSnapshotCompiler(cacheDirectoryURL: cacheURL)
                .compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)
            XCTAssertEqual(compiled.decision(for: "m.example.org").reason, .blocklist)

            let scratchRoot = cacheURL.appendingPathComponent("streaming-compile-scratch", isDirectory: true)
            let afterCompile = (try? FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)) ?? []
            XCTAssertTrue(afterCompile.isEmpty, "Successful compile must leave no per-compile scratch dir")

            // Simulate a jetsam-orphaned scratch dir, then sweep.
            let orphan = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            try Data("x".utf8).write(to: orphan.appendingPathComponent("block-domains.blob"))
            CachedFilterSnapshotCompiler.sweepStaleScratch(cacheDirectoryURL: cacheURL)
            let afterSweep = (try? FileManager.default.contentsOfDirectory(atPath: scratchRoot.path)) ?? []
            XCTAssertTrue(afterSweep.isEmpty, "sweepStaleScratch must remove orphaned scratch dirs")
        }
    }

    // MARK: Helpers (replicated minimally from BlocklistCatalogSyncTests)

    /// The bytes after the file header (magic[8] + version[4] + metadataLen[4] + metadata),
    /// i.e. the three rule tables — the region `writeStreaming` is responsible for.
    private static func ruleTableRegion(of data: Data) -> Data {
        let bytes = [UInt8](data)
        precondition(bytes.count >= 16)
        let metaLen = Int(bytes[12]) | (Int(bytes[13]) << 8) | (Int(bytes[14]) << 16) | (Int(bytes[15]) << 24)
        let headerLen = 16 + metaLen
        return data.subdata(in: headerLen..<data.count)
    }

    private func hash(_ text: String) -> String {
        BlocklistCatalogSynchronizer.sha256Hex(of: Data(text.utf8))
    }

    private func makeSource(id: String, sourceHash: String) -> CatalogBlocklistSource {
        CatalogBlocklistSource(
            id: id,
            name: id,
            category: "security",
            riskLevel: "normal",
            defaultEnabled: true,
            licenseName: "Test",
            attribution: "Test",
            projectURL: URL(string: "https://example.com/project")!,
            sourceURL: URL(string: "https://example.com/\(id)")!,
            versionID: "\(id)-v1",
            entryCount: 0,
            byteSize: 0,
            sourceHash: sourceHash,
            acceptedSourceHashes: [
                CatalogAcceptedSourceHash(sha256: sourceHash, byteSize: 16, entryCount: 1)
            ],
            normalizedHash: sourceHash,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            redistributionMode: "source_url_only",
            parseFormat: .plainDomains,
            licenseTextURL: nil,
            noticeURL: nil
        )
    }

    private func makeCatalog(sources: [CatalogBlocklistSource]) -> BlocklistCatalog {
        BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260101T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sources: sources,
            guardrails: []
        )
    }

    private func writeCatalog(_ catalog: BlocklistCatalog, to cacheURL: URL) throws {
        let dir = cacheURL.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
        try data.write(to: dir.appendingPathComponent("latest.json"))
    }

    private func writeLatestBlocklist(_ text: String, sourceID: String, to cacheURL: URL) throws {
        let dir = cacheURL
            .appendingPathComponent("blocklists", isDirectory: true)
            .appendingPathComponent(sourceID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: dir.appendingPathComponent("latest.txt"))
    }
}
