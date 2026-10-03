import Foundation
import LavaSecKit

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

/// The threat intersection retains heap strings, unlike the streamed block entry table.
/// A separate pre-insertion bound keeps that transient small and fails closed for app preparation.
struct StreamingCompileGuardrailBudgetExceeded: LocalizedError {
    let ruleCount: Int

    var errorDescription: String? {
        "Retaining \(ruleCount) threat guardrails exceeds the in-extension heap budget "
            + "(\(FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount)). "
            + "Deferring to the app to prepare it."
    }
}

/// The tunnel holds at most the configured allowances, never the full guardrail
/// source. Ancestor checks walk hostname labels; reversed names make descendant
/// allowances a contiguous range for each streamed guardrail rule.
struct AllowedSuffixIntersectionIndex: Sendable {
    private let allowedRules: DomainRuleSet
    private let reversedDomains: [(key: String, domain: String)]

    init(normalizedDomains: [String]) {
        let unique = Set(normalizedDomains)
        allowedRules = DomainRuleSet(suffixDomains: unique)
        reversedDomains = unique.map { (String($0.reversed()), $0) }
            .sorted { $0.key < $1.key }
    }

    var isEmpty: Bool { reversedDomains.isEmpty }

    func containsAncestor(of domain: String) -> Bool {
        allowedRules.containsNormalized(domain)
    }

    func forEachDescendant(of domain: String, _ visit: (String) throws -> Void) rethrows {
        let prefix = String(domain.reversed()) + "."
        var lower = 0
        var upper = reversedDomains.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if reversedDomains[middle].key < prefix {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        while lower < reversedDomains.count, reversedDomains[lower].key.hasPrefix(prefix) {
            try visit(reversedDomains[lower].domain)
            lower += 1
        }
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
///      an on-disk blob and recording only a compact `Entry` (a 4-byte offset; the
///      length rides in the blob as a 1-byte prefix, ~4 B/rule) in
///      heap — NO per-source `DomainRuleSet` is ever built, so a single source's size no
///      longer bounds the compile; only the aggregate entry arrays grow (gated per-rule, so a
///      too-large config fails closed instead of overshooting or truncating);
///   2. sorts + dedups the entry arrays (not the blob — the decoder only requires the
///      ENTRIES byte-sorted, so the insertion-order blob with its dead duplicate bytes is
///      a valid backing store);
///   3. streams a byte-valid `CompactFilterSnapshot` to disk via
///      `CompactFilterSnapshot.writeStreaming` (the single source of truth for the format);
///   4. memory-maps and decodes it, so the resident snapshot costs ~entries only (the
///      domain bytes are file-backed/paged) — the same 4 B/rule shape the app produces.
///
/// The allow rules are small and built in heap. The allowed-domain-intersected threat
/// rules have a separate pre-insertion heap budget: a single broad allowance can contain
/// many descendants. `baseSnapshot` already carries the manual block rules AND any QA probe domains
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
        stampIdentity: PreparedFilterSnapshotIdentity? = nil,
        retainedArtifactURL: URL? = nil
    ) async throws -> CompactFilterSnapshot {
        guard baseSnapshot.nonAllowableThreatRules.count <= FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount else {
            throw StreamingCompileGuardrailBudgetExceeded(ruleCount: baseSnapshot.nonAllowableThreatRules.count)
        }
        let synchronizer = BlocklistCatalogSynchronizer(
            cacheDirectoryURL: cacheDirectoryURL,
            parseBudget: .inExtension
        )

        let scratchDir = Self.scratchRootURL(cacheDirectoryURL: cacheDirectoryURL)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratchDir, withIntermediateDirectories: true)
        // On success we either promote the artifact OUT of scratch (retention) or map then
        // drop it (its inode stays pinned past unlink, or, if `.mappedIfSafe` declined to
        // map, the bytes are already a heap copy) — so it is always safe to remove the
        // whole scratch dir here. A retained artifact lives outside the scratch root, so
        // neither this removal nor `sweepStaleScratch` ever touches it.
        defer { try? FileManager.default.removeItem(at: scratchDir) }

        let blobURL = scratchDir.appendingPathComponent("block-domains.blob")
        // Class-None at creation (INV-PERSIST-2). Unlike the retained artifact — which is promoted
        // out of scratch by a same-volume rename that inherits this class — this blob is NEVER
        // promoted: it is mmap'd inline below (`Data(contentsOf:options:.mappedIfSafe)`) and removed
        // by the scratch `defer`. It is still stamped Class-None because the in-extension compile
        // mmaps it and the boot tunnel can run BEFORE first unlock, when a Class-C blob would be
        // unreadable and the pre-unlock compile would fail. Stamping at birth is the only option —
        // there is no post-creation re-stamp on this transient blob.
        guard FileManager.default.createFile(
            atPath: blobURL.path,
            contents: nil,
            attributes: SharedStateFileProtection.controlPlaneCreationAttributes
        ) else {
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

        func reserveAggregateRule() throws {
            let nextCount = aggregateCount + 1
            guard nextCount <= FilterSnapshotMemoryBudget.maxStreamingCompileRuleCount else {
                throw StreamingCompileBudgetExceeded(ruleCount: nextCount)
            }
            aggregateCount = nextCount
        }

        func appendDomain(_ domain: String, isSuffix: Bool) throws {
            let bytes = Data(domain.utf8)
            // In-extension we MUST NOT crash on a pathological domain (the in-heap encoder
            // `precondition`s); throw so the caller falls back fail-CLOSED instead.
            // A 1-byte length prefix caps the domain at 255 bytes — normalized domains are
            // ≤253, so this is enforced, not merely assumed.
            guard bytes.count <= Int(UInt8.max) else {
                throw CompactFilterSnapshotError.domainTooLong(domain)
            }
            guard blobOffset + 1 + bytes.count <= Int(UInt32.max) else {
                throw CompactFilterSnapshotError.artifactTooLarge
            }
            // Reserve before growing either entry array or the write buffer.
            try reserveAggregateRule()
            let entry = UInt32(blobOffset)
            if isSuffix {
                suffixEntries.append(entry)
            } else {
                exactEntries.append(entry)
            }
            writeBuffer.append(UInt8(bytes.count))
            writeBuffer.append(bytes)
            blobOffset += 1 + bytes.count
            if writeBuffer.count >= CompactFilterSnapshot.streamingFlushThreshold {
                try blobHandle.lavaWrite(writeBuffer)
                writeBuffer.removeAll(keepingCapacity: true)
            }
        }

        // Threat rules intersect the allowed suffix scopes; their descendant count is NOT
        // bounded by the number of allowances. When there are no allowed
        // domains the effective threat set is empty regardless, so we skip streaming the
        // guardrails entirely. Otherwise each streamed rule queries the bounded
        // allowance index — the full guardrail union is never resident.
        let normalizedAllowedDomains = configuration.allowedDomains.compactMap { try? DomainName.normalize($0) }
        let allowedIndex = AllowedSuffixIntersectionIndex(normalizedDomains: normalizedAllowedDomains)
        let needGuardrails = includesGuardrails && !allowedIndex.isEmpty
        var effectiveThreat = DomainRuleSet()

        func appendThreat(_ domain: String, isSuffix: Bool) throws {
            let rule = try DomainRule(domain: domain, matchesSubdomains: isSuffix)
            // Duplicate source lines and overlapping allowances must not consume another
            // entry. Coverage membership would wrongly merge exact and suffix semantics.
            guard !effectiveThreat.containsRule(rule) else { return }
            let nextCount = effectiveThreat.count + 1
            guard nextCount <= FilterSnapshotMemoryBudget.maxStreamingHeapGuardrailRuleCount else {
                throw StreamingCompileGuardrailBudgetExceeded(ruleCount: nextCount)
            }
            try reserveAggregateRule()
            effectiveThreat.insert(rule)
        }

        // INV-TIER-1 stamp input: the recorded tier total must match the cold gate's
        // formula, whose block part is `list-merge (WITHOUT manual) + blockedDomains` —
        // but the deduped tables below fold manual in, collapsing any manual domain a
        // list also carries. `blockRuleCount + |manual ∩ lists|` reconstructs the cold
        // block part exactly (collapsed manual domains are re-counted once, disjoint
        // ones are already in the table once and in no list), so count the overlap
        // during streaming. Bounded by the manual cap (25 free / 1,000 Plus) — a tiny
        // Set, never list-sized (INV-MEM-1). Suffix-only on both sides: manual rules
        // are always suffix, and a byte-equal EXACT list rule does not collapse with a
        // manual suffix entry (both survive the table dedup), matching the cold gate's
        // separate counting. (PR #335 Codex P2 rounds 3+4: adding blockedDomains
        // wholesale over-records by |manual ∖ lists|; omitting it under-records by
        // |manual ∩ lists|.)
        let manualSuffixDomains = Set(configuration.blockedDomains.compactMap { try? DomainName.normalize($0) })
        var manualDomainsMatchedInLists: Set<String> = []

        let load = try await synchronizer.streamCachedForInExtensionCompile(
            enabledSourceIDs: configuration.enabledBlocklistIDs,
            customSources: configuration.customBlocklists,
            includesGuardrails: needGuardrails,
            onBlockRule: { domain, matchesSubdomains in
                if matchesSubdomains, manualSuffixDomains.contains(domain) {
                    manualDomainsMatchedInLists.insert(domain)
                }
                try appendDomain(domain, isSuffix: matchesSubdomains)
            },
            onGuardrailRule: { domain, matchesSubdomains in
                // Preserve exact/suffix semantics and every overlapping allowed
                // descendant without comparing this rule to every allowance.
                if allowedIndex.containsAncestor(of: domain) {
                    try appendThreat(domain, isSuffix: matchesSubdomains)
                }
                if matchesSubdomains {
                    try allowedIndex.forEachDescendant(of: domain) { allowed in
                        try appendThreat(allowed, isSuffix: true)
                    }
                }
            }
        )

        // Every enabled ID must produce a source or be explicitly withdrawn by the admitted
        // catalog. Record withdrawals in the summary so omission is never inferred from absence.
        // pinned: CatalogAuthorizationTests.testWithdrawalsRequireConfiguredVerifiedAuthorization
        let withdrawnIDs = load.resolvedCatalog.withdrawnBlocklistIDs(in: configuration)
        for sourceID in configuration.enabledBlocklistIDs
            where !load.deliveredBlockSourceIDs.contains(sourceID) && !withdrawnIDs.contains(sourceID) {
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
        // The base contribution has the same unique-entry and aggregate gates as streamed
        // threats. Its count was checked before scratch allocation, so these sorted views
        // are bounded too; an unchecked union would reopen the heap-budget bypass.
        for domain in baseSnapshot.nonAllowableThreatRules.exactDomainList {
            try appendThreat(domain, isSuffix: false)
        }
        for domain in baseSnapshot.nonAllowableThreatRules.suffixDomainList {
            try appendThreat(domain, isSuffix: true)
        }

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
            // cosmetic — including for a RETAINED artifact whose header a later cold start
            // re-reads via `readSummary`: `coversEnabledBlocklists` checks key presence (not
            // the value), and the authoritative resident count is `blockRuleCount` (from the
            // deduped tables), which every reuse/budget/cap gate sums.
            blocklistRuleCount: load.perSourceRuleCounts.values.reduce(0, +),
            blocklistSourceRuleCounts: load.perSourceRuleCounts,
            blockRuleCount: blockRuleCount,
            // The resident (decoded) snapshot RECOMPUTES this from the tables, `readSummary`
            // does not cross-check it (unlike the three counts above), and no tunnel read
            // gate consumes it from a summary — so the placeholder stays safe even for a
            // retained artifact.
            blockedDomainRuleCount: blockRuleCount,
            allowRuleCount: allowRules.count,
            guardrailRuleCount: threatRules.count,
            // INV-TIER-1: the tunnel's serve gates bind the RECORDED tier total and fail
            // closed on nil, so the retained artifact must stamp one or it becomes
            // unloadable on the next cold start. This reconstructs the cold gate's block
            // part EXACTLY: `blockRuleCount + |manual ∩ lists|` = list-merge + manual
            // (see the overlap-counting comment above the stream). Residual deltas vs the
            // cold total, both documented and bounded: the full-guardrail term (only the
            // allowlist-overlap subset is ever materialized here; the guardrail tier is
            // empty in production today) and raw-vs-normalized manual counting (the cold
            // gate counts raw blockedDomains entries; the table counts normalized-unique
            // ones — sub-cap noise). App-published artifacts, which record the exact
            // total, remain the dominant serve path. PR #335 Codex P1 + P2 rounds.
            tierBudgetRuleCount: blockRuleCount
                + manualDomainsMatchedInLists.count
                + allowRules.count
                + threatRules.count,
            quarantinedBlocklistIDs: withdrawnIDs.isEmpty ? nil : withdrawnIDs
        )

        let identity = stampIdentity ?? PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: load.resolvedCatalog
        )

        let outputURL = scratchDir.appendingPathComponent("snapshot.lscfsnp")
        // Class-None at creation, same as the blob (INV-PERSIST-2): this file becomes the
        // retained artifact via moveItem, inheriting exactly the class stamped here.
        guard FileManager.default.createFile(
            atPath: outputURL.path,
            contents: nil,
            attributes: SharedStateFileProtection.controlPlaneCreationAttributes
        ) else {
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

        // Best-effort retention: promote the fully-synchronized artifact out of scratch
        // (same-volume rename, so it is atomic and never observable half-written) so it
        // survives the process and the next cold start can fast-resume from it instead of
        // paying this compile again. A prior retained artifact's live mapping stays valid
        // past the swap (the rename replaces the directory entry, not the mapped inode).
        // Retention failure must never fail the compile — fall back to mapping the
        // scratch copy exactly as before.
        var mappedURL = outputURL
        if let retainedArtifactURL {
            do {
                try FileManager.default.createDirectory(
                    at: retainedArtifactURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Promote WITHOUT preserving destination metadata (INV-PERSIST-2):
                // replaceItemAt can carry the DESTINATION's protection class onto the
                // replaced item, so a pre-INV-PERSIST-2 Class-C retained artifact could
                // re-class every republish — and a post-hoc re-stamp can FAIL before first
                // unlock (re-classing an existing file re-encrypts it, which needs the
                // still-locked class key), leaving a locked file to be mapped below and
                // failing the very compile the boot tunnel depends on (PR #378 review).
                // removeItem+moveItem makes the promoted file carry the scratch file's
                // Class-None from creation, unconditionally. Losing replace-atomicity is
                // fine: this is a same-process cache, and a crash between the two calls
                // costs one recompile on the next start.
                try? FileManager.default.removeItem(at: retainedArtifactURL)
                try FileManager.default.moveItem(at: outputURL, to: retainedArtifactURL)
                // Belt-and-braces re-stamp: a no-op for the just-moved scratch file (its
                // class was stamped at creation), kept for defense in depth. Its result is
                // deliberately ignored — the moved file already carries Class-None, so the
                // mapped read below cannot hit a locked file.
                SharedStateFileProtection.applyControlPlaneProtection(at: retainedArtifactURL)
                mappedURL = retainedArtifactURL
            } catch {
                mappedURL = outputURL
            }
        }

        let mappedData = try Data(contentsOf: mappedURL, options: [.mappedIfSafe])
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
        let lhsOffset = Int(lhs)
        let rhsOffset = Int(rhs)
        let lhsLength = Int(table[lhsOffset])
        let rhsLength = Int(table[rhsOffset])
        let lhsStart = lhsOffset + 1
        let rhsStart = rhsOffset + 1
        let shared = min(lhsLength, rhsLength)
        var index = 0
        while index < shared {
            let l = table[lhsStart + index]
            let r = table[rhsStart + index]
            if l != r {
                return l < r ? -1 : 1
            }
            index += 1
        }
        if lhsLength == rhsLength {
            return 0
        }
        return lhsLength < rhsLength ? -1 : 1
    }
}
