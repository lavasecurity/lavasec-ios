import XCTest
@testable import LavaSecCore

/// Covers the in-extension streaming compile (`StreamingCompactSnapshotCompiler` via the
/// `CachedFilterSnapshotCompiler` facade) and the shared on-disk writer
/// (`CompactFilterSnapshot.writeStreaming`): byte-format parity with the in-heap encoder,
/// the `readSummary` cross-check on streamed bytes, end-to-end equivalence with an in-heap
/// union reference, and scratch cleanup.
final class StreamingCompactSnapshotCompilerTests: XCTestCase {

    // MARK: writeStreaming — byte-format single source of truth

    /// `writeStreaming` must emit bytes identical to the in-heap `encodedData()` when given
    /// the same (sorted) tables, and the result must pass the strict `decode` and the cheap
    /// `readSummary` cross-check. Also locks the no-cross-dedup invariant: a domain present
    /// as BOTH an exact and a suffix rule stays in both tables.
    func testWriteStreamingMatchesInHeapEncoderAndPassesReaders() throws {
        let exactDomains = ["a.example.com", "x.example.com"]
        let suffixDomains = ["x.example.com", "z.example.com"] // x.example.com in both tables

        // Build the blob + entries exactly as `CompactDomainRuleTableBuilder` does (exact
        // sorted, then suffix sorted, into one contiguous blob with monotonic offsets).
        var blob = Data()
        var exactEntries: [CompactDomainRuleSet.Entry] = []
        for domain in exactDomains {
            let bytes = Data(domain.utf8)
            exactEntries.append(.init(offset: UInt32(blob.count), length: UInt16(bytes.count)))
            blob.append(bytes)
        }
        var suffixEntries: [CompactDomainRuleSet.Entry] = []
        for domain in suffixDomains {
            let bytes = Data(domain.utf8)
            suffixEntries.append(.init(offset: UInt32(blob.count), length: UInt16(bytes.count)))
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

        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
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

    // MARK: End-to-end compiler — equivalence with an in-heap union reference

    /// Compiling two sources that share a domain (plus a manual block rule) must produce the
    /// same deduped block count and the same decisions as an in-heap union of the same
    /// sources — proving cross-source dedup and the full streaming pipeline.
    func testStreamingCompileDedupesAcrossSourcesAndMatchesUnionReference() async throws {
        let textA = "ads.example.com\nshared.example.com\n"
        let textB = "shared.example.com\ntrackers.example.net\n"
        let sourceA = makeSource(id: "source-a", sourceHash: hash(textA))
        let sourceB = makeSource(id: "source-b", sourceHash: hash(textB))
        let catalog = makeCatalog(sources: [sourceA, sourceB])

        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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

        for domain in ["ads.example.com", "shared.example.com", "trackers.example.net", "manual.example.org"] {
            XCTAssertEqual(compiled.decision(for: domain).reason, .blocklist, "\(domain) should be blocked")
        }
        XCTAssertEqual(compiled.decision(for: "not-blocked.example.com").reason, .defaultAllow)
        XCTAssertEqual(compiled.resolver, configuration.resolverPreset)
    }

    /// A single source far larger than the old per-source cap (~183K) compiles in FULL —
    /// the streaming parse never builds a per-source Set, so it is bounded only by the
    /// aggregate, NOT silently truncated. (This is the regression the streaming-parse fix
    /// closes: before it, a >183K source was truncated and served under the full identity.)
    func testLargeSourceCompilesInFullWithoutTruncation() async throws {
        let ruleCount = 200_000 // > the former ~183,500 in-extension per-source cap
        var lines = ""
        lines.reserveCapacity(ruleCount * 22)
        for index in 0..<ruleCount {
            lines += "d\(index).example.com\n"
        }
        let source = makeSource(id: "big-source", sourceHash: hash(lines))
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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

    // 1Hosts Xtra — the largest single list a user realistically adds — is 663,491 rules /
    // 12.2 MB in adblock form (per the list's own header, 2026-06-21). This proves an
    // Xtra-sized single source streams through the in-extension compile IN FULL: no
    // truncation, no per-source dirty `Set`, comfortably under the streaming ceiling, and
    // with the served snapshot well under the device memory budget. 700K brackets Xtra with
    // margin, and ~14 MB of raw payload also exercises the 25 MB in-extension intake cap.
    func testXtraSizedSingleSourceCompilesInFullInExtension() async throws {
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
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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
        // The served, mapped-compact snapshot (~9 B/rule) stays within the device budget.
        XCTAssertFalse(FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiled.blockRuleCount))
    }

    /// Guardrails intersected with the allowlist: an allowed domain that a guardrail source
    /// blocks becomes a non-allowable threat rule (and the guardrail union is never resident).
    func testGuardrailIntersectionWithAllowlist() async throws {
        let blockText = "ads.example.com\n"
        let guardrailText = "evil.example.com\n" // suffix rule for evil.example.com
        let blockSource = makeSource(id: "block-src", sourceHash: hash(blockText))
        let guardrailSource = makeSource(id: "guard-src", sourceHash: hash(guardrailText))
        let catalog = BlocklistCatalog(
            schemaVersion: 2,
            catalogVersion: "20260101T000000Z",
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            sources: [blockSource],
            guardrails: [guardrailSource]
        )
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
        try writeCatalog(catalog, to: cacheURL)
        try writeLatestBlocklist(blockText, sourceID: blockSource.id, to: cacheURL)
        try writeLatestBlocklist(guardrailText, sourceID: guardrailSource.id, to: cacheURL)

        // sub.evil.example.com is allowlisted but the guardrail blocks evil.example.com (suffix),
        // so it must stay blocked as a threatGuardrail (the allow can't override the guardrail).
        let configuration = AppConfiguration(
            enabledBlocklistIDs: [blockSource.id],
            allowedDomains: ["sub.evil.example.com", "safe.example.com"]
        )
        let compiled = try await CachedFilterSnapshotCompiler(
            cacheDirectoryURL: cacheURL,
            includesGuardrails: true
        ).compile(baseSnapshot: configuration.filterSnapshot(), configuration: configuration)

        XCTAssertEqual(compiled.decision(for: "sub.evil.example.com").reason, .threatGuardrail)
        XCTAssertEqual(compiled.decision(for: "safe.example.com").reason, .localAllowlist)
        XCTAssertEqual(compiled.decision(for: "ads.example.com").reason, .blocklist)
    }

    /// An enabled-but-empty config with only manual block rules still compiles to a valid
    /// mapped snapshot blocking the manual domains.
    func testStreamingCompileWithManualBlockRulesOnly() async throws {
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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

    /// An enabled source with no catalog or custom entry must fail explicitly (fail-closed),
    /// same as the app's gate.
    func testStreamingCompileFailsForEnabledIDWithoutSource() async throws {
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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

    // MARK: Cleanup

    /// A successful compile leaves no scratch behind (it maps the artifact then removes the
    /// per-compile dir; the mapping survives via inode pinning), and `sweepStaleScratch`
    /// removes any orphan a jetsam-killed compile would leave.
    func testCompileCleansScratchAndSweepRemovesOrphans() async throws {
        let cacheURL = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: cacheURL) }
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

    private func makeScratchDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
