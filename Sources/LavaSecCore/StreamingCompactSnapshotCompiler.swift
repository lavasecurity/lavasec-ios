import Foundation

/// Thrown by the in-extension streaming compile when the configuration's aggregate rule
/// count exceeds `FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount` — i.e. the
/// compact entry arrays it must sort/dedup in heap would risk the packet-tunnel jetsam
/// budget. The tunnel caller catches it and fails CLOSED; the foreground app then
/// re-prepares the full mapped-compact artifact. A standalone error so it needs no
/// `BlocklistCatalogSyncError` enum/switch changes.
struct StreamingCompileBudgetExceeded: LocalizedError {
    let ruleCount: Int

    var errorDescription: String? {
        "Configuration's aggregate of \(ruleCount) rules exceeds the in-extension streaming "
            + "compile budget (\(FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount)). "
            + "Deferring to the app to prepare it."
    }
}

/// Compiles the runtime filter snapshot INSIDE the packet-tunnel extension without ever
/// holding the dirty `DomainRuleSet` union of all enabled block sources in memory — the
/// transient that can blow the ~50 MiB jetsam budget for a large multi-list configuration.
///
/// Instead of unioning every source's `Set<String>` and then compacting (the app's path,
/// fine under ample memory), it:
///   1. STREAM-PARSES each source straight through `BlocklistParser.forEachBlockRule`
///      (`streamCachedForInExtensionCompile`), appending each accepted rule's domain bytes to
///      an on-disk blob and recording only a compact `Entry` (offset + length, ~8 B/rule) in
///      heap — NO per-source `DomainRuleSet` is ever built, so a single source's size no
///      longer bounds the compile; only the aggregate entry arrays grow (gated per-rule, so a
///      too-large config fails closed instead of overshooting or truncating);
///   2. sorts + dedups the entry arrays (not the blob — the decoder only requires the
///      ENTRIES byte-sorted, so the insertion-order blob with its dead duplicate bytes is
///      a valid backing store);
///   3. streams a byte-valid `CompactFilterSnapshot` to disk via
///      `CompactFilterSnapshot.writeStreaming` (the single source of truth for the format);
///   4. memory-maps and decodes it, so the resident snapshot costs ~entries only (the
///      domain bytes are file-backed/paged) — the same 9 B/rule shape the app produces.
///
/// The allow rules and the (allowed-domain-intersected) threat rules are small and built
/// in heap. `baseSnapshot` already carries the manual block rules AND any QA probe domains
/// (its `applyingQAProbeSet` ran in `AppConfiguration.filterSnapshot()`), so they are folded
/// in by appending `baseSnapshot.blockRules`/`allowRules`/`nonAllowableThreatRules` — no
/// QA-specific code lives here.
struct StreamingCompactSnapshotCompiler: Sendable {
    let cacheDirectoryURL: URL
    let includesGuardrails: Bool

    init(cacheDirectoryURL: URL, includesGuardrails: Bool = true) {
        self.cacheDirectoryURL = cacheDirectoryURL
        self.includesGuardrails = includesGuardrails
    }

    /// Scratch root (under the catalog cache dir, NOT the artifact store / publish pointer)
    /// for the per-compile temp blob + output file. `sweepStaleScratch` removes orphans a
    /// jetsam-killed compile may leave behind.
    static func scratchRootURL(cacheDirectoryURL: URL) -> URL {
        cacheDirectoryURL.appendingPathComponent("streaming-compile-scratch", isDirectory: true)
    }

    /// Best-effort removal of every per-compile scratch subdirectory. Call this ONLY at
    /// tunnel start, before any compile spawns — NOT before each compile: it removes every
    /// scratch dir unconditionally, so calling it while a concurrent compile holds an
    /// in-flight UUID dir would delete that compile's blob/output. A successful compile maps
    /// then unlinks its own artifact (the inode stays pinned) and a live process removes its
    /// own dir via `defer`, so the only orphans are from a hard kill — which always restarts
    /// the extension, re-running the startup sweep.
    static func sweepStaleScratch(cacheDirectoryURL: URL) {
        let root = scratchRootURL(cacheDirectoryURL: cacheDirectoryURL)
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for entry in entries {
            try? FileManager.default.removeItem(at: entry)
        }
    }

    func compile(
        baseSnapshot: FilterSnapshot,
        configuration: AppConfiguration,
        stampIdentity: PreparedFilterSnapshotIdentity? = nil
    ) async throws -> CompactFilterSnapshot {
        let synchronizer = BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheDirectoryURL,
            parseBudget: .inExtension
        )

        let scratchDir = Self.scratchRootURL(cacheDirectoryURL: cacheDirectoryURL)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        // On success we map then drop the artifact (its inode stays pinned past unlink, or,
        // if `.mappedIfSafe` declined to map, the bytes are already a heap copy) — so it is
        // always safe to remove the whole scratch dir here.
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let blobURL = scratchDir.appendingPathComponent("block-domains.blob")
        guard FileManager.default.createFile(atPath: blobURL.path, contents: nil) else {
            throw CompactFilterSnapshotError.truncatedData
        }
        let blobHandle = try FileHandle(forWritingTo: blobURL)
        var blobHandleOpen = true
        defer { if blobHandleOpen { try? blobHandle.close() } }

        var exactEntries: [CompactDomainRuleSet.Entry] = []
        var suffixEntries: [CompactDomainRuleSet.Entry] = []
        var blobOffset = 0
        var aggregateCount = 0
        var writeBuffer = Data()
        writeBuffer.reserveCapacity(CompactFilterSnapshot.streamingFlushThreshold + 256)

        func appendDomain(_ domain: String, isSuffix: Bool) throws {
            let bytes = Data(domain.utf8)
            // In-extension we MUST NOT crash on a pathological domain (the in-heap encoder
            // `precondition`s); throw so the caller falls back fail-CLOSED instead.
            guard bytes.count <= Int(UInt16.max) else {
                throw CompactFilterSnapshotError.domainTooLong(domain)
            }
            guard blobOffset + bytes.count <= Int(UInt32.max) else {
                throw CompactFilterSnapshotError.artifactTooLarge
            }
            let entry = CompactDomainRuleSet.Entry(offset: UInt32(blobOffset), length: UInt16(bytes.count))
            if isSuffix {
                suffixEntries.append(entry)
            } else {
                exactEntries.append(entry)
            }
            writeBuffer.append(bytes)
            blobOffset += bytes.count
            aggregateCount += 1
            // Per-DOMAIN gate: fail closed the instant the entry arrays cross the ceiling.
            // Because sources stream in uncapped (no per-source Set), this is what bounds a
            // single huge source — it stops the parse mid-source (the throw propagates up
            // through `forEachBlockRule`) instead of overshooting by a whole source.
            if aggregateCount > FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount {
                throw StreamingCompileBudgetExceeded(ruleCount: aggregateCount)
            }
            if writeBuffer.count >= CompactFilterSnapshot.streamingFlushThreshold {
                try blobHandle.lavaWrite(writeBuffer)
                writeBuffer.removeAll(keepingCapacity: true)
            }
        }

        // Threat rules are the guardrail set intersected with the user's allowed domains,
        // so they are bounded by `allowedDomains.count` (tiny). When there are no allowed
        // domains the effective threat set is empty regardless, so we skip streaming the
        // guardrails entirely. Otherwise each streamed guardrail rule is checked against the
        // small allowlist — the full guardrail union is never resident.
        let normalizedAllowedDomains = configuration.allowedDomains.compactMap { try? DomainName.normalize($0) }
        let needGuardrails = includesGuardrails && !normalizedAllowedDomains.isEmpty
        var effectiveThreat = DomainRuleSet()

        let load = try await synchronizer.streamCachedForInExtensionCompile(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            customSources: configuration.customBlocklists,
            includesGuardrails: needGuardrails,
            onBlockRule: { domain, matchesSubdomains in
                try appendDomain(domain, isSuffix: matchesSubdomains)
            },
            onGuardrailRule: { domain, matchesSubdomains in
                // Reproduce `nonAllowableRulesForAllowedDomains` over the streamed guardrail
                // union: an allowed domain is non-allowable iff the guardrails contain it — a
                // suffix rule `g` covers `g` and anything under it; an exact rule covers only
                // `g`. (Union of per-rule matches == matching the union; `contains` is
                // monotonic.)
                for allowed in normalizedAllowedDomains {
                    let blocked = matchesSubdomains
                        ? (allowed == domain || allowed.hasSuffix("." + domain))
                        : (allowed == domain)
                    if blocked {
                        try? effectiveThreat.insert(domain: allowed, matchesSubdomains: true)
                    }
                }
            }
        )

        // Every enabled ID must have produced a source (catalog or custom), matching the
        // app's gate — otherwise we'd silently serve a snapshot missing an enabled list.
        for sourceID in configuration.enabledBlocklistIDs
            where !load.deliveredBlockSourceIDs.contains(sourceID) {
            throw BlocklistCatalogSyncError.missingEnabledBlocklistSource(sourceID: sourceID)
        }

        // `baseSnapshot` already merged the manual block rules and applied the QA probe set
        // (in `AppConfiguration.filterSnapshot()`), so folding its rules reproduces the old
        // `CachedFilterSnapshotCompiler` + `applyingQAProbeSet` result without any
        // QA-specific code here.
        for domain in baseSnapshot.blockRules.exactDomainList {
            try appendDomain(domain, isSuffix: false)
        }
        for domain in baseSnapshot.blockRules.suffixDomainList {
            try appendDomain(domain, isSuffix: true)
        }
        effectiveThreat.formUnion(baseSnapshot.nonAllowableThreatRules)

        if !writeBuffer.isEmpty {
            try blobHandle.lavaWrite(writeBuffer)
            writeBuffer.removeAll(keepingCapacity: true)
        }
        try blobHandle.synchronize()
        try blobHandle.close()
        blobHandleOpen = false

        // Sort + dedup the entry arrays against the on-disk blob (mapped read-only, paged —
        // not a heap copy of the domain bytes). The decoder requires byte-sorted entries.
        let blobData = try Data(contentsOf: blobURL, options: [.mappedIfSafe])
        Self.sortAndDedupEntries(&exactEntries, blob: blobData)
        Self.sortAndDedupEntries(&suffixEntries, blob: blobData)

        let allowRules = CompactDomainRuleSet(ruleSet: baseSnapshot.allowRules)
        let threatRules = CompactDomainRuleSet(ruleSet: effectiveThreat)

        let blockRuleCount = exactEntries.count + suffixEntries.count
        let summary = PreparedFilterSnapshotSummary(
            // These per-source / aggregate counts are PRE-dedup emit counts (the streaming
            // parse keeps no per-source Set), so they can exceed the app's deduped
            // per-source counts when a source has internal/cross-source duplicates. That is
            // cosmetic here: `coversEnabledBlocklists` checks key presence (not the value),
            // the authoritative resident count is `blockRuleCount` (from the deduped tables),
            // and this artifact is mapped-then-unlinked so its header is never re-read via
            // `readSummary`.
            blocklistRuleCount: load.perSourceRuleCounts.values.reduce(0, +),
            blocklistSourceRuleCounts: load.perSourceRuleCounts,
            blockRuleCount: blockRuleCount,
            // Stored only in the metadata header for `readSummary`'s fast path; the resident
            // (decoded) snapshot RECOMPUTES this from the tables, and this artifact is
            // ephemeral (never re-read via `readSummary`). `readSummary` does not cross-check
            // it (unlike the three counts above), so a placeholder is safe.
            blockedDomainRuleCount: blockRuleCount,
            allowRuleCount: allowRules.count,
            guardrailRuleCount: threatRules.count
        )

        let identity = stampIdentity ?? PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: load.resolvedCatalog
        )

        let outputURL = scratchDir.appendingPathComponent("snapshot.lscfsnp")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil) else {
            throw CompactFilterSnapshotError.truncatedData
        }
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        var outputHandleOpen = true
        defer { if outputHandleOpen { try? outputHandle.close() } }

        try CompactFilterSnapshot.writeStreaming(
            to: outputHandle,
            identity: identity,
            generatedAt: baseSnapshot.generatedAt,
            resolver: configuration.resolverPreset,
            summary: summary,
            blockExactEntries: exactEntries,
            blockSuffixEntries: suffixEntries,
            blockDomainDataURL: blobURL,
            blockDomainDataCount: blobOffset,
            allowRules: allowRules,
            nonAllowableThreatRules: threatRules
        )
        try outputHandle.synchronize()
        try outputHandle.close()
        outputHandleOpen = false

        let mappedData = try Data(contentsOf: outputURL, options: [.mappedIfSafe])
        return try CompactFilterSnapshot.decode(from: mappedData)
    }

    /// Sorts `entries` into byte-lexicographic order of the domain bytes they point at in
    /// `blob`, then drops adjacent-equal entries (dedup). Matches
    /// `CompactDomainRuleSet`'s lookup ordering (raw unsigned-byte compare on the
    /// ASCII-normalized domains), so the written table passes the decoder's
    /// `entriesAreSorted` invariant. Sort is in place; dedup compacts in place — no
    /// per-entry heap growth.
    private static func sortAndDedupEntries(_ entries: inout [CompactDomainRuleSet.Entry], blob: Data) {
        guard !entries.isEmpty else { return }
        blob.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            entries.sort { lhs, rhs in
                Self.compareEntryBytes(raw, lhs, rhs) < 0
            }
            var writeIndex = 1
            for readIndex in 1..<entries.count {
                if Self.compareEntryBytes(raw, entries[writeIndex - 1], entries[readIndex]) != 0 {
                    entries[writeIndex] = entries[readIndex]
                    writeIndex += 1
                }
            }
            entries.removeLast(entries.count - writeIndex)
        }
    }

    /// Unsigned byte-lexicographic comparison of two entries' stored bytes in `table`
    /// (mirrors `CompactDomainRuleSet.compareTableSlices`). Returns <0, 0, or >0.
    private static func compareEntryBytes(
        _ table: UnsafeRawBufferPointer,
        _ lhs: CompactDomainRuleSet.Entry,
        _ rhs: CompactDomainRuleSet.Entry
    ) -> Int {
        let lhsOffset = Int(lhs.offset)
        let rhsOffset = Int(rhs.offset)
        let shared = min(Int(lhs.length), Int(rhs.length))
        var index = 0
        while index < shared {
            let l = table[lhsOffset + index]
            let r = table[rhsOffset + index]
            if l != r {
                return l < r ? -1 : 1
            }
            index += 1
        }
        if lhs.length == rhs.length {
            return 0
        }
        return lhs.length < rhs.length ? -1 : 1
    }
}
