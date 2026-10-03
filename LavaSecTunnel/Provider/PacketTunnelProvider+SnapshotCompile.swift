@preconcurrency import ActivityKit
import Foundation
import Darwin
import Network
@preconcurrency import NetworkExtension
import Security
@preconcurrency import UserNotifications
import LavaSecChainedUpstream
import LavaSecDNS
import LavaSecFilterPipeline
import LavaSecKit

// One concern of `PacketTunnelProvider`, split out of the former single-file provider.
// Stored state lives in LavaSecTunnel/PacketTunnelProvider.swift (extensions cannot declare
// stored properties, so a property declared beside its concern moved there); the other
// `PacketTunnelProvider+*.swift` files each hold one `// MARK:` section of the class, and the
// remaining files under Provider/ hold the types the single file declared outside it.

extension PacketTunnelProvider {
    // MARK: - Snapshot compile, artifact stores & fast-resume

    func loadCompiledSnapshot(
        configuration: AppConfiguration,
        generation: UInt64
    ) async -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
        let cachedCatalog = loadCachedCatalogMetadata()
        let expectedIdentity = PreparedFilterSnapshotIdentity.make(
            configuration: configuration,
            catalog: cachedCatalog
        )

        // Try the pointer-resolved (versioned) artifact set first, then the legacy
        // root set. A pointer that lags the root — a partially-failed publish that
        // wrote root but did not flip the pointer, a surviving current.json after
        // rolling back to a root-only build that rewrote root, or a versioned dir GC'd
        // in this pass's post-resolve/pre-open window — must NOT shadow the fresh root
        // copy: a miss (rejected identity, or a nil read from an evicted dir) retries
        // the root store before the in-extension recompile. Each store is read as a
        // single resolved unit, so compact + prepared within one store never mix
        // generations.
        var artifactStores: [(store: FilterArtifactStore, route: String)] = []
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if let resolved = readableArtifactStore() {
                let route = resolved.directoryURL == rootStore.directoryURL ? "root" : "resolved"
                artifactStores.append((store: resolved, route: route))
            }
            if artifactStores.first?.store.directoryURL != rootStore.directoryURL {
                artifactStores.append((store: rootStore, route: "root"))
            }
        }
        // The tunnel's own retained compile is the LAST candidate: identical identity/
        // budget gating to the app stores (reusableCompactSnapshot), it only wins when
        // the app-published stores miss — the stale-store state where the only
        // alternative is repeating the streaming compile. Being in this list also makes
        // it a last-known-good candidate for serveLastKnownGoodOrFailClosed, which is
        // deliberate: it is the user's own previously-compiled, config-exact rules, and
        // canServeAsLastKnownGood applies the same never-fail-open gates to it.
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            artifactStores.append((store: tunnelCompiledStore, route: "tunnel-compiled"))
        }

        var missedOverTierBudget = false
        var missedOverMemoryBudget = false
        for (artifactStore, route) in artifactStores {
            // Both reads gate (reuse + budget) BEFORE the multi-MB decode and re-validate
            // from consistent bytes, so a stale/over-budget artifact is never materialized
            // before the root fallback, and a concurrent atomic rewrite of the mutable
            // root store cannot slip a different generation past the header check.
            let compactResult = reusableCompactSnapshot(
                from: artifactStore,
                configuration: configuration,
                cachedCatalog: cachedCatalog
            )
            if let compactSnapshot = compactResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-hit", details: [
                    "identity": compactSnapshot.identity.fingerprint,
                    "route": route
                ])
                return (compactSnapshot, compactSnapshot.identity)
            }

            let preparedResult = reusablePreparedSnapshot(
                from: artifactStore,
                configuration: configuration,
                cachedCatalog: cachedCatalog
            )
            if let preparedSnapshot = preparedResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-hit", details: [
                    "identity": preparedSnapshot.identity.fingerprint,
                    "route": route
                ])
                return (preparedSnapshot.snapshot, preparedSnapshot.identity)
            }

            if compactResult.missReason == "over-tier-budget" || preparedResult.missReason == "over-tier-budget" {
                missedOverTierBudget = true
            }
            if compactResult.missReason == "over-budget" || preparedResult.missReason == "over-budget" {
                missedOverMemoryBudget = true
            }

            // WHICH ARTIFACT, AND WHICH IDENTITY WE WANTED. The reason strings name the FIELDS that
            // differed; they cannot say which SIDE is stale, and the two directions produce an
            // identical signature. A published artifact for a filter the tunnel has not adopted yet,
            // and an adopted config the pointer has not caught up with, both read as
            // `reuse:inputs:selectedSourceVersionIDs+selectedSourceHashes` on the same catalog.
            //
            // The field case that forced this (2026-09-01): a preset switch persisted, the app
            // reported success, and 21 consecutive reloads missed here — the capture could not say
            // whether the app published the wrong artifact or the tunnel wanted the wrong identity,
            // so neither side could be fixed on evidence.
            //
            // `artifactToken` is the versioned directory name, which IS `<fingerprint>-<millis>`
            // (`FilterArtifactStore.versionedToken`), so it carries the FOUND identity for free and
            // pairs with the app's `snapshot-publish-outcome.publishedArtifactToken`. Three
            // comparisons then separate every case: token == published ⇒ the tunnel read what the
            // app wrote (so a mismatch is the tunnel's expected identity); token != published ⇒ the
            // pointer is stale; token prefix == expectedSnapshotFingerprint ⇒ identity agreed and
            // something else rejected it.
            //
            // ONLY the `resolved` route is a versioned directory, so only there is
            // `lastPathComponent` that token. The root store's directory IS the app-group container
            // (`lastPathComponent` is a UUID on device) and the tunnel-compiled store's is the
            // constant `tunnel-compiled-artifact`; emitting either would put a device identifier in
            // a user-shareable report under a key documented as a content hash, and would read as
            // "the pointer is stale" in the pairing above when it is not. Root-route misses are
            // ROUTINE — the 2026-09-01 capture logs one on every reload — so this is the common
            // path, not an edge. The test is on the ROUTE, not the store, because the resolved
            // store is itself labelled `root` when the pointer resolves to the root store, and
            // that case is a container directory too (Kilo review, PR #640).
            //
            // With that guard both emitted values are content hashes of configuration inputs or a
            // fixed literal — no domain, rule, filter name, or user text.
            // pinned: FilterSwitchPublishDiagnosticsSourceTests.testTheStoreMissNamesTheArtifactItRejected
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-store-miss", details: [
                "route": route,
                "compactReason": compactResult.missReason ?? "unknown",
                "preparedReason": preparedResult.missReason ?? "unknown",
                "artifactToken": route == "resolved" ? artifactStore.directoryURL.lastPathComponent : "non-versioned",
                "expectedSnapshotFingerprint": expectedIdentity.fingerprint,
                "generation": "\(generation)"
            ])
        }

        let baseSnapshot = configuration.filterSnapshot()

        // Shared build-failure path. A fresh (re)compile could not be produced — most
        // often the rotating-upstream / stale-pinned-hash wedge, where the cached catalog
        // rotated past the on-disk artifact (so the strict reuse gate above missed) AND
        // the in-extension recompile throws checksumMismatch against the stale cached
        // source content. On a COLD start there is no in-memory resident to keep, so the
        // caller would otherwise fail CLOSED and clear protection to zero. Instead, serve
        // a config-matched last-known-good artifact (same enabled-list set / manual rules /
        // custom fingerprints / parser version — only the catalog/guardrail content hashes
        // are stale), returning its OWN stale identity so a later reload swaps in fresh
        // rules once the app republishes a buildable artifact. Falls through to the
        // empty-config pass-through, or nil (fail-closed) for a non-empty config with no
        // serviceable artifact.
        //
        // DISK FALLBACK IS COLD-START ONLY. On a live reload that still holds a healthy
        // FILTERING resident (the catalog rotated but the in-memory snapshot is fine), we
        // must NOT decode a disk artifact: returning nil lets loadSnapshotInBackground take
        // its existing keep-resident branch, which avoids the multi-MB decode and the
        // 2x-resident memory peak that could jetsam the extension on a near-budget snapshot.
        // When the caller freed the resident pre-decode its identity is already nil, so this
        // gate correctly falls through to the disk fallback (no resident left to keep) —
        // making it equivalent to the caller's `hasResidentSnapshot && !freedResidentBeforeDecode
        // && currentResidentSnapshotHasEnabledFilters()` keep condition.
        func serveLastKnownGoodOrFailClosed() -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
            // ROOT guard for the superseded-fallback class (Codex #213): if this reload was already
            // superseded, DO NOT decode a multi-MB last-known-good. The stale generation's commit is
            // rejected anyway, and the decode can overlap the winning compile and recreate the peak
            // the gate prevents. Return nil so the caller re-checks the generation and bails cleanly
            // (loadSnapshot-skipped-stale-missing). Gating HERE covers EVERY fallback caller — missing
            // catalog, over-budget, and the compile-error catch — not only the compile-skip paths.
            guard self.isCurrentSnapshotReloadGeneration(generation) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-fallback-skipped-stale", details: [
                    "generation": "\(generation)"
                ])
                return nil
            }
            // KEEPING THE RESIDENT ONLY OUTRANKS A STALE ARTIFACT WHILE THE RESIDENT IS THE SAME
            // FILTER. This gate was written for a failed RECOMPILE, where the resident is the same
            // configuration and simply fresher — there, preferring it is right. After a
            // CONFIGURATION CHANGE it is the opposite: the resident is the filter the user just
            // turned OFF, and preferring it enforces a choice they have replaced, for as long as
            // the reload keeps failing. That is not a degraded outcome, it is the wrong filter.
            //
            // Field evidence (2026-09-01): a switch to a lighter preset published an artifact whose
            // selection matched exactly — same enabled lists, same manual rules, same catalog
            // version, coverage satisfied — and the strict reuse gate rejected it on
            // `selectedSourceVersionIDs`+`selectedSourceHashes` alone, pure catalog freshness. With
            // a heavier preset resident, this gate then skipped the last-known-good search that
            // would have adopted it, and 21 consecutive reloads kept the heavier preset for 40
            // minutes. A protection restart fixed it precisely because a fresh process has no
            // resident, so the bootstrap's own last-known-good accepted the very same artifact.
            //
            // So the resident keeps its precedence only when it still answers the request. A
            // resident that differs on SELECTION (`selectionMismatches`, never on freshness) yields
            // to a config-exact last-known-good, which `canServeAsLastKnownGood` already gates on
            // the same never-fail-open terms: exact enabled-list set, manual rules,
            // custom-list fingerprints, resolver transport, coverage, and the current parser
            // version. Stale content of the RIGHT filter beats fresh content of the WRONG one.
            //
            // `?? false` also carries the previous `!= nil` test: no resident is not a keepable
            // one, and the `&&` still short-circuits the second snapshotQueue hop exactly as
            // before, so this adds no state access and no ordering (INV-QUEUE-1 unchanged).
            // pinned: FilterSwitchPublishDiagnosticsSourceTests.testAStaleCorrectFilterOutranksAFreshResidentOne
            let residentAnswersThisRequest = self.currentResidentSnapshotIdentity().map {
                $0.selectionMismatches(against: expectedIdentity).isEmpty
            } ?? false
            let hasKeepableFilteringResident = residentAnswersThisRequest
                && self.currentResidentSnapshotHasEnabledFilters()
            if !hasKeepableFilteringResident, !configuration.enabledBlocklistIDs.isEmpty {
                for (artifactStore, route) in artifactStores {
                    if let lastGood = self.lastKnownGoodCompactSnapshot(
                        from: artifactStore,
                        configuration: configuration
                    ) {
                        LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good", details: [
                            "identity": lastGood.identity.fingerprint,
                            "route": route
                        ])
                        return (lastGood, lastGood.identity)
                    }
                }
            }
            return configuration.enabledBlocklistIDs.isEmpty ? (baseSnapshot, expectedIdentity) : nil
        }

        guard let catalogCacheURL else {
            return serveLastKnownGoodOrFailClosed()
        }
        // An oversized candidate does not exclude a smaller, configuration-matched fallback.
        if missedOverMemoryBudget {
            return serveLastKnownGoodOrFailClosed()
        }

        // INV-TIER-1 + INV-MEM-1: skip a compile DOOMED by the tier cap. A store miss with
        // reason "over-tier-budget" means an identity-valid artifact for exactly this
        // configuration + catalog was rejected ONLY for its recorded tier total — a fresh
        // compile of the same inputs deterministically reproduces an over-tier result, so
        // running it would spend the ~32 MiB peak once per reload tick, forever, in the
        // over-budget steady state (the retained artifact it writes is itself tier-rejected
        // on the next read, so the retain never terminates the loop the way it does for
        // ordinary recompiles). Genuinely-new content never takes this branch: a moved
        // catalog changes the expected identity, so the miss reason is "reuse:...", not
        // "over-tier-budget". An UNRECORDED total ("tier-budget-unrecorded", a legacy or
        // pre-stamp artifact) deliberately does NOT set this flag — that recompile is the
        // repair path that stamps the missing total for an in-budget configuration (PR #335
        // Codex P1 round 2). Degrade exactly like an over-tier compile result: LKG if one
        // fits the budget, else fail-closed (INV-DNS-1), while the app-side gates surface
        // the actionable tier error.
        if missedOverTierBudget {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-over-tier-budget", details: [
                "generation": "\(generation)"
            ])
            return serveLastKnownGoodOrFailClosed()
        }

        // INV-MEM-1: skip a DOOMED compile. A newer reload only bumps the generation (it fences
        // the commit); without this the superseded compile still runs its full ~32 MiB peak.
        // Re-check the reload generation IMMEDIATELY before the compiler so a reload the app
        // (or the Focus poll) has already superseded never spends the peak. Return nil, NOT the
        // fallback (Codex #213): a superseded generation must not materialize a multi-MB
        // last-known-good decode that its own commit would discard — that decode can overlap the
        // winning compile and reintroduce the peak this gate prevents. The caller's `guard let
        // else` re-checks the generation and bails cleanly (loadSnapshot-skipped-stale-missing);
        // the winning generation's own compile commits the real snapshot.
        guard isCurrentSnapshotReloadGeneration(generation) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-stale", details: [
                "generation": "\(generation)"
            ])
            return nil
        }

        // INV-MEM-1 × INV-CHAIN-2 (plan D3): never run the in-extension compile while the chained upstream
        // is co-resident. The streaming compile peaks around 32 MiB; the WireGuard engine and
        // its session state are resident for the whole chained session, and the NE process has
        // a ~50 MB ceiling. The feasibility work named the reload collision as the worst case,
        // and it is a collision the user triggers by ordinary means — a pull-to-refresh while
        // chained.
        //
        // This suppresses the COMPILE, not the artifact. Every store above, including the
        // tunnel's own previously-compiled one, is still a candidate and is served mmap'd at
        // roughly 9 B/rule; only the path that would build a new one here is closed. Degrading
        // through serveLastKnownGoodOrFailClosed keeps INV-DNS-1's order intact — config-exact
        // last-known-good first, block-all only if there is none — so the tunnel never fails
        // open, and the app compensates by preparing and publishing before it starts a chained
        // session (the existing enableProtection ordering).
        // pinned: TunnelDataPathLatchSourceTests.testTheInExtensionCompileIsSuppressedWhileChained
        //
        // Placed after the generation guard on purpose: a superseded reload should bail without
        // materializing a multi-MB last-known-good decode, which is the same reasoning that
        // makes the guard above return nil rather than the fallback.
        if currentTunnelDataPathMode().isChainedUpstream {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-chained", details: [
                "generation": "\(generation)"
            ])
            return serveLastKnownGoodOrFailClosed()
        }

        do {
            // NOTE: scratch from a jetsam-killed compile is swept ONCE at startTunnel, not
            // here — sweeping per-compile would race a concurrent reload's in-flight scratch.
            //
            // INV-MEM-1: run the compile behind snapshotCompileGate so at most one ~32 MiB peak is
            // resident at a time — two overlapping reloads (start + pull-to-refresh) would
            // otherwise peak ≈60 MiB in the 50 MB-limited NE process and jetsam the tunnel.
            // Only the compile is serialized (the cheap header reads above stay concurrent);
            // the gate holds exclusivity across the WHOLE await, unlike a bare actor.
            let compiled = try await snapshotCompileGate.run { [weak self] in
                // INV-MEM-1 (Codex #213): re-check the reload generation AFTER the gate grants exclusivity.
                // The pre-gate check only catches supersession BEFORE entering the gate; a reload that
                // queued behind an earlier compile can be superseded WHILE it waits its turn. Re-check
                // here so a now-doomed compile never spends its ~32 MiB peak (its commit would be
                // rejected anyway). isCurrentSnapshotReloadGeneration hops to dnsStateQueue, so it is
                // safe from this off-queue task context; the latest generation still passes and compiles.
                guard self?.isCurrentSnapshotReloadGeneration(generation) ?? false else {
                    throw SnapshotCompileSuperseded()
                }
                // Retain the compiled artifact at the tunnel-compiled path so the NEXT
                // cold start fast-resumes from this compile instead of repeating it (and
                // taking the transient fail-closed bootstrap window again). Best-effort
                // inside the compiler; a superseded compile may briefly retain older
                // inputs, which every reader rejects via the identity gate until the
                // winning compile atomically replaces the file.
                let compiledSnapshot = try await CachedFilterSnapshotCompiler(
                    cacheDirectoryURL: catalogCacheURL
                ).compile(
                    baseSnapshot: baseSnapshot,
                    configuration: configuration,
                    stampIdentity: expectedIdentity,
                    retainedArtifactURL: self?.tunnelCompiledArtifactStore?.compactSnapshotURL
                )
                // Post-compile re-check, STILL INSIDE the gate (Codex #213 P1): a reload can be
                // superseded WHILE this compile runs. Returning the result here would complete
                // `run` and RELEASE the gate, letting the next queued compile start while this stale
                // caller still holds its multi-MB compiled snapshot — the two overlap and recreate
                // the peak the gate exists to prevent. Re-check before returning so a mid-compile
                // supersession discards the result inside the gate (the next compile is still
                // waiting), not after release.
                guard self?.isCurrentSnapshotReloadGeneration(generation) ?? false else {
                    throw SnapshotCompileSuperseded()
                }
                return compiledSnapshot
            }
            // The streaming compile returns a MEMORY-MAPPED CompactFilterSnapshot (entries
            // resident ~9 B/rule, domain bytes paged from disk) — never a dirty union — so it
            // is gated by the compact device budget, the same ceiling the app's mapped artifact
            // uses (`maxFilterRuleCount`), NOT the dirty per-source/transient caps the compiler
            // already enforced and failed closed under. After the parserRulesVersion bump this
            // fallback is exactly what runs on the first post-upgrade start before the app
            // regenerates artifacts. Over budget → we must NOT resident-load it (jetsam), but a
            // same-config catalog rotation can make a FRESH compile over-budget while an older
            // compact artifact for the same config is still within budget — so route through the
            // last-known-good fallback (itself budget-gated, so it can only serve an in-budget
            // artifact) rather than clearing protection. Falls through to fail-closed if there
            // is none, so the app re-prepares.
            let compiledRuleCount = compiled.blockRuleCount + compiled.allowRuleCount + compiled.guardrailRuleCount
            if FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: compiledRuleCount) {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compiled-over-budget", details: [
                    "ruleCount": "\(compiledRuleCount)",
                    "maxRuleCount": "\(FilterSnapshotMemoryBudget.maxFilterRuleCount)"
                ])
                return serveLastKnownGoodOrFailClosed()
            }
            // INV-TIER-1: the in-extension compile enforces only memory caps while it runs
            // (per-source/streaming budgets), so a persisted over-budget configuration —
            // a lapsed-Plus selection or an upstream-grown union — would recompile here
            // tier-blind. Gate the RECORDED total the streaming compiler just stamped (its
            // conservative equivalent of the app formula; nil ⇒ fail toward the fallback,
            // matching the load gates). Route over-tier results through the same degrade
            // order as over-memory: last-known-good (itself tier- and budget-gated, so it
            // can only serve an in-budget artifact) → fail-closed, and the app's gated
            // prepare surfaces the actionable tier error (INV-DNS-1 order preserved).
            if !FilterRuleBudget.fitsTierBudget(
                recordedTotal: compiled.tierBudgetRuleCount,
                maxFilterRules: configuration.limits.maxFilterRules
            ) {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compiled-over-tier-budget", details: [
                    "tierBudgetRuleCount": compiled.tierBudgetRuleCount.map(String.init) ?? "nil",
                    "maxFilterRules": "\(configuration.limits.maxFilterRules)"
                ])
                return serveLastKnownGoodOrFailClosed()
            }
            return (compiled, expectedIdentity)
        } catch is SnapshotCompileSuperseded {
            // A newer reload superseded this one while it waited in the compile gate — skipped the
            // peak. Return nil, NOT the fallback (Codex #213): after the gate wait the winning reload
            // is likely already compiling, so decoding a multi-MB last-known-good here (which this
            // stale generation's own commit would discard) can overlap that compile and reintroduce
            // the peak the gate exists to prevent. The caller re-checks the generation and bails
            // cleanly (loadSnapshot-skipped-stale-missing). Not an error.
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compile-skipped-stale-in-gate", details: [
                "generation": "\(generation)"
            ])
            return nil
        } catch {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-cache-compile-error", details: Self.errorDebugDetails(error))
            return serveLastKnownGoodOrFailClosed()
        }
    }

    /// Thrown inside the compile gate when a reload is superseded while awaiting its turn, so the
    /// doomed compile bails before spending its memory peak (INV-MEM-1, Codex #213). Sendable so it can
    /// cross the gate's `@Sendable` operation boundary.
    private struct SnapshotCompileSuperseded: Error {}

    // Reads a store's compact bytes ONCE and returns the decoded snapshot only when it
    // is reusable for `configuration` and within the rule budget — the gate and the
    // decode share the SAME bytes (`.mappedIfSafe` pins the inode), so a concurrent
    // atomic rewrite of the mutable root store cannot slip a different or over-budget
    // generation past the header check, and a stale/over-budget artifact is never
    // materialized before the root fallback.
    private func reusableCompactSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?,
        syncDecodeRuleCap: Int? = nil
    ) -> (snapshot: CompactFilterSnapshot?, missReason: String?) {
        guard FileManager.default.fileExists(atPath: store.compactSnapshotURL.path) else {
            return (nil, "missing")
        }
        guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]) else {
            return (nil, "unreadable")
        }
        guard let summary = try? CompactFilterSnapshot.readSummary(from: data) else {
            return (nil, "invalid")
        }
        if let reuseRejection = compactReuseRejectionReason(
            summary: summary,
            configuration: configuration,
            cachedCatalog: cachedCatalog
        ) {
            return (nil, "reuse:\(reuseRejection)")
        }

        let ruleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        // AUTHORITATIVE sync-cap check, on the SAME mmapped bytes that will be decoded
        // (`.mappedIfSafe` pins the inode). Only the cold-start bootstrap passes a cap; the async
        // path passes nil. The bootstrap's cheap pre-gate is best-effort — an atomic republish of
        // the mutable root store between the pre-gate read and this read could otherwise slip an
        // over-cap (but in-budget) artifact into a synchronous decode — so the cap is re-enforced
        // here, against the decode bytes, to defer it off the ready path. The bootstrap excludes
        // legacy artifacts, so the summary read above is the cheap skip path (no full decode).
        if let syncDecodeRuleCap, ruleCount > syncDecodeRuleCap {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-over-sync-cap", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)",
                "syncCap": "\(syncDecodeRuleCap)"
            ])
            return (nil, "over-sync-cap")
        }
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-over-budget", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return (nil, "over-budget")
        }

        // INV-TIER-1 serve backstop: the reuse identity contains no isPaid input, so an artifact
        // compiled under Plus stays identity-valid after a lapse — this is the last gate before
        // those rules are LOADED into service (an already-resident snapshot is the documented
        // INV-TIER-1 carve-out until its next adopting reload). The cap is read from the decoded
        // shared configuration's derived limits, never as a feature switch (the tunnel's behavior
        // is otherwise tier-blind). It binds the RECORDED tier total from the header metadata — the
        // resident table sum under-counts it by the full-guardrail term (only the allowlist-overlap
        // subset is resident), which would let a recorded-over artifact keep serving (PR #335
        // Codex P1). The two rejection reasons are deliberately DISTINCT: an UNRECORDED total
        // (legacy/unstamped artifact) must let the recompile run — it stamps a fresh total and
        // repairs the store — while a recorded-OVER total marks the recompile doomed and the
        // loader short-circuits it (PR #335 Codex P1 round 2).
        guard let recordedTierBudget = summary.tierBudgetRuleCount else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-tier-budget-unrecorded", details: [
                "identity": summary.identity.fingerprint
            ])
            return (nil, "tier-budget-unrecorded")
        }
        guard FilterRuleBudget.fitsTierBudget(
            compiledTotal: recordedTierBudget,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-compact-over-tier-budget", details: [
                "identity": summary.identity.fingerprint,
                "tierBudgetRuleCount": "\(recordedTierBudget)",
                "maxFilterRules": "\(configuration.limits.maxFilterRules)"
            ])
            return (nil, "over-tier-budget")
        }

        guard let snapshot = try? CompactFilterSnapshot.decode(from: data) else {
            return (nil, "decode-failed")
        }
        return (snapshot, nil)
    }

    private func compactReuseRejectionReason(
        summary: CompactFilterSnapshotSummary,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> String? {
        guard summary.resolver.transport == configuration.resolverPreset.transport else {
            return "resolverTransport"
        }

        if !configuration.enabledBlocklistIDs.isEmpty {
            guard cachedCatalog != nil else { return "noCachedCatalog" }
            guard summary.coversEnabledBlocklists(in: configuration) else { return "coverage" }
        }

        if let cachedCatalog {
            let expectedIdentity = PreparedFilterSnapshotIdentity.make(
                configuration: configuration,
                catalog: cachedCatalog
            )
            // Shared with the app's `FilterArtifactManifest.reuseRejectionReason` so a capture's
            // two sides can never label the same rejection differently.
            return summary.identity.reuseMismatchReason(against: expectedIdentity)
        }

        return summary.identity.hasSameConfigurationInputs(as: configuration) ? nil : "configInputs"
    }

    // Last-known-good fallback for a failed fresh (re)compile (the rotating-upstream /
    // stale-pinned-hash wedge). Mirrors `reusableCompactSnapshot` — single `.mappedIfSafe`
    // read, header gate BEFORE the multi-MB decode, budget gate, decode from the SAME
    // bytes — but swaps the strict catalog-hash reuse gate for `canServeAsLastKnownGood`,
    // which tolerates ONLY stale catalog/guardrail content hashes while still requiring the
    // same configuration inputs + coverage + resolver transport. So it never fails OPEN (the
    // enabled-list set must match exactly) and a parser-rules bump still forces a
    // regenerate; it only re-serves the user's own previously-compiled, previously-verified
    // rules a few hours stale rather than clearing protection to zero on a cold start.
    // Compact-only by design: the store always dual-writes compact+prepared, and any
    // prepared-only artifact predates the parser-version field (decodes as 0) so a current
    // build regenerates it regardless — there is nothing a prepared fallback could serve.
    private func lastKnownGoodCompactSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration,
        syncDecodeRuleCap: Int? = nil
    ) -> CompactFilterSnapshot? {
        guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]),
              let summary = try? CompactFilterSnapshot.readSummary(from: data),
              summary.canServeAsLastKnownGood(for: configuration)
        else {
            return nil
        }

        let ruleCount = summary.blockRuleCount + summary.allowRuleCount + summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good-over-budget", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return nil
        }

        // INV-TIER-1: LKG is config-exact (INV-DNS-3), and an over-budget artifact is exactly
        // config-exact after a lapse — without this gate the LKG fallback would re-serve the
        // rules every other serve gate just rejected. Binds the RECORDED total (nil fails
        // closed), like every serve gate. No LKG candidate ⇒ fail-closed, never fail open
        // (INV-DNS-1). The nil and over-limit rejections log DISTINCT events, like the
        // strict compact path: exported field logs redact detail values (LAV-94), so the
        // event name alone must say which one happened — "unrecorded" is a legacy artifact
        // that heals on the next stamped write, "over" is a real tier violation (the
        // 2026-07-10 UR-48 field log logged a pre-#335 unrecorded artifact as over-tier,
        // hiding why LKG declined the bootstrap).
        guard let recordedTierBudget = summary.tierBudgetRuleCount else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good-tier-budget-unrecorded", details: [
                "identity": summary.identity.fingerprint
            ])
            return nil
        }
        guard FilterRuleBudget.fitsTierBudget(
            compiledTotal: recordedTierBudget,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good-over-tier-budget", details: [
                "identity": summary.identity.fingerprint,
                "tierBudgetRuleCount": "\(recordedTierBudget)",
                "maxFilterRules": "\(configuration.limits.maxFilterRules)"
            ])
            return nil
        }

        // Synchronous callers (the cold-start bootstrap) re-enforce their decode cap HERE, on
        // the same mmapped bytes this decode reads (INV-MEM-2): the bootstrap's readSyncBootstrapInfo
        // pre-gate is a separate earlier read, so an atomic republish between the two could
        // otherwise slip an over-cap artifact into a synchronous decode on startTunnel — the
        // exact TOCTOU the strict path closes with reusableCompactSnapshot's syncDecodeRuleCap
        // (PR #330 review).
        if let syncDecodeRuleCap, ruleCount > syncDecodeRuleCap {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-last-known-good-over-sync-cap", details: [
                "identity": summary.identity.fingerprint,
                "ruleCount": "\(ruleCount)",
                "syncCap": "\(syncDecodeRuleCap)"
            ])
            return nil
        }

        return try? CompactFilterSnapshot.decode(from: data)
    }

    // Cold-start ONLY: the synchronous fast-resume decode is attempted up to this rule count.
    // Measured CompactFilterSnapshot.decode (release) ≈ 0.18 ms / 1K rules — the O(rules)
    // sorted-order verification dominates — so ~1M ≈ ~180 ms on a Mac / ~0.4–0.5 s on device.
    // Above the cap, fail-closed bootstrap defers the decode to the async load (a brief window)
    // rather than stalling tunnel-ready ~0.5 s+ on EVERY connect for a near-budget filter.
    private static let maxSynchronousBootstrapRuleCount = 1_000_000

    // Synchronous cold-start fast-resume: returns the user's own STRICT-reusable, in-budget,
    // summary-schema on-disk snapshot (the current artifact) so a fresh process — notably one
    // relaunched by a self-reconnect that killed the previous process — does NOT serve a block-all
    // FailClosedRuntimeSnapshot window while the async load decodes. Reuses the SAME budget/header-
    // gated reuseCompactSnapshot as the async path, capped to the synchronous-decode ceiling.
    // On a strict miss it falls back to the config-exact LAST-KNOWN-GOOD artifact (INV-DNS-3
    // gates: exact enabled-list set / manual rules / custom fingerprints / parser version —
    // only catalog content hashes may be stale), so the first post-rotation start filters with
    // yesterday's rules for the few seconds the fresh compile runs instead of blocking all DNS
    // (founder decision 2026-07-09, UR-48 Phase 2a plan — the async path already served LKG for
    // hours on compile failure, so refusing it here for a ~7 s window was inconsistent).
    // Returns nil (→ fail-closed bootstrap, async load resumes) when NEITHER a strict nor an
    // LKG-eligible in-budget summary-schema artifact exists. NEVER fails open: LKG can serve
    // stale rules but never a different configuration's rules.
    func bootstrapResidentSnapshotFromDisk(
        configuration: AppConfiguration
    ) -> (snapshot: any FilterRuntimeSnapshot, identity: PreparedFilterSnapshotIdentity)? {
        let cachedCatalog = loadCachedCatalogMetadata()
        let cap = Self.maxSynchronousBootstrapRuleCount

        // Same [pointer-resolved, root, tunnel-compiled] store order as
        // loadCompiledSnapshot — a stale pointer must not shadow a fresh root copy, and
        // the app-published stores are preferred over the tunnel's own retained compile
        // (identity gating makes the order correctness-neutral; preference only decides
        // which equally-reusable copy is decoded).
        var artifactStores: [(store: FilterArtifactStore, route: String)] = []
        if let containerURL = LavaSecAppGroup.containerURL {
            let rootStore = FilterArtifactStore(directoryURL: containerURL)
            if let resolved = readableArtifactStore() {
                let route = resolved.directoryURL == rootStore.directoryURL ? "root" : "resolved"
                artifactStores.append((store: resolved, route: route))
            }
            if artifactStores.first?.store.directoryURL != rootStore.directoryURL {
                artifactStores.append((store: rootStore, route: "root"))
            }
        }
        if let tunnelCompiledStore = retainedTunnelCompiledArtifactStoreIfPresent() {
            artifactStores.append((store: tunnelCompiledStore, route: "tunnel-compiled"))
        }

        // Cheap, skip-only gate BEFORE any reuse/LKG read (which call readSummary). Two reasons
        // it must happen here and not inside the helpers:
        //  1. CAP — readSummary's cheap path only applies to summary-schema artifacts; for a
        //     legacy artifact it FULL-DECODES the rule tables, so checking the cap after
        //     readSummary would make a large legacy artifact pay a full decode just to be rejected.
        //  2. LEGACY EXCLUSION — even UNDER the cap, a legacy artifact would be decoded twice
        //     synchronously (readSummary's legacy recompute, then reusableCompactSnapshot's
        //     decode), ~2x the sync budget. Legacy artifacts are transient (regenerated on the
        //     next publish), so skip them and let the async load decode them once off the
        //     critical path. readSyncBootstrapInfo reports both signals in one skip-only read.
        // The same filter yields the same count across stores.
        var maxRuleCount = 0
        var eligibleStores: [(store: FilterArtifactStore, route: String)] = []
        for (store, route) in artifactStores {
            guard FileManager.default.fileExists(atPath: store.compactSnapshotURL.path) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "missing"
                ])
                continue
            }
            guard let data = try? Data(contentsOf: store.compactSnapshotURL, options: [.mappedIfSafe]) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "unreadable"
                ])
                continue
            }
            guard let info = try? CompactFilterSnapshot.readSyncBootstrapInfo(from: data) else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "invalid"
                ])
                continue
            }
            maxRuleCount = max(maxRuleCount, info.totalRuleCount)
            guard info.hasStoredSummary else {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-skip-legacy-artifact", details: [
                    "route": route,
                    "ruleCount": "\(info.totalRuleCount)"
                ])
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "legacy",
                    "ruleCount": "\(info.totalRuleCount)"
                ])
                continue
            }
            if info.totalRuleCount > cap {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-over-sync-cap", details: [
                    "route": route,
                    "ruleCount": "\(info.totalRuleCount)",
                    "syncCap": "\(cap)"
                ])
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                    "route": route,
                    "reason": "over-sync-cap",
                    "ruleCount": "\(info.totalRuleCount)",
                    "syncCap": "\(cap)"
                ])
                continue
            }
            eligibleStores.append((store: store, route: route))
        }

        for (store, route) in eligibleStores {
            let compactResult = reusableCompactSnapshot(
                from: store,
                configuration: configuration,
                cachedCatalog: cachedCatalog,
                syncDecodeRuleCap: cap
            )
            if let compact = compactResult.snapshot {
                LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-compact-resume", details: [
                    "route": route,
                    "identity": compact.identity.fingerprint
                ])
                return (compact, compact.identity)
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-store-miss", details: [
                "route": route,
                "reason": compactResult.missReason ?? "unknown",
                "syncCap": "\(cap)"
            ])
        }
        // Strict miss → try config-exact last-known-good over the SAME sync-eligible stores
        // (already pre-gated to summary-schema and the sync decode cap above, so this stays
        // bounded on the startTunnel path). lastKnownGoodCompactSnapshot applies the INV-DNS-3
        // gates + the authoritative budget re-check on the same mmapped bytes it decodes.
        // Trade-off accepted by the 2026-07-09 decision: until the async compile commits, this
        // serves rules that may predate the current catalog — including the over-cap case,
        // where the async path lands on the SAME LKG via serveLastKnownGoodOrFailClosed anyway.
        // The LKG identity carries stale hashes, so the async no-op reload gate can never treat
        // it as current — the fresh (re)compile always still runs and replaces it.
        for (store, route) in eligibleStores {
            guard let lastKnownGood = lastKnownGoodCompactSnapshot(
                from: store,
                configuration: configuration,
                syncDecodeRuleCap: cap
            ) else {
                continue
            }
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-last-known-good-resume", details: [
                "route": route,
                "identity": lastKnownGood.identity.fingerprint
            ])
            return (lastKnownGood, lastKnownGood.identity)
        }

        // Neither strict nor last-known-good → fail closed; the async load handles everything
        // else off the critical path. NEVER fail open.
        LavaSecDeviceDebugLog.append(component: "tunnel", event: "bootstrap-fast-resume-miss", details: [
            "reason": eligibleStores.isEmpty ? "no-eligible-stores" : "strict-and-lkg-miss",
            "storeCount": "\(artifactStores.count)",
            "eligibleStoreCount": "\(eligibleStores.count)",
            "syncCap": "\(cap)",
            "maxRuleCount": "\(maxRuleCount)"
        ])
        return nil
    }

    // Legacy fallback. The manifest and the prepared file are read SEPARATELY (prepared
    // is JSON with no cheap header, so — unlike `reusableCompactSnapshot` — the gate and
    // the decode can't share one mmapped `Data`). The manifest pre-gate (identity +
    // budget, manifest written LAST) only skips a doomed decode; it is NOT the authority.
    // Because the mutable root store can be atomically republished between the two reads,
    // a concurrent publish could otherwise pair gen-N's in-budget manifest with gen-(N+1)'s
    // over-budget prepared bytes. So after decoding we re-bind the prepared to the manifest
    // (identity, generatedAt, summary — mirroring `FilterArtifactStore.preparedSelection`)
    // and re-check the budget against the prepared's OWN summary, making the over-budget
    // refusal TOCTOU-safe like the compact path. The versioned store is immutable, so this
    // skew only exists on root; the cross-check is cheap and closes it everywhere.
    private func reusablePreparedSnapshot(
        from store: FilterArtifactStore,
        configuration: AppConfiguration,
        cachedCatalog: BlocklistCatalog?
    ) -> (snapshot: PreparedFilterSnapshot?, missReason: String?) {
        guard FileManager.default.fileExists(atPath: store.manifestURL.path) else {
            return (nil, "manifest-missing")
        }
        guard let manifest = (try? store.loadManifest()).flatMap({ $0 }) else {
            return (nil, "manifest-invalid")
        }
        if let reuseRejection = manifest.reuseRejectionReason(
            configuration: configuration,
            cachedCatalog: cachedCatalog
        ) {
            return (nil, "reuse:\(reuseRejection)")
        }

        let manifestRuleCount = manifest.summary.blockRuleCount + manifest.summary.allowRuleCount + manifest.summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: manifestRuleCount) else {
            return (nil, "over-budget")
        }
        // INV-TIER-1 cheap pre-gate on the manifest's RECORDED total (see
        // reusableCompactSnapshot for why the table sum can't substitute, and for the
        // unrecorded/over split — unrecorded must not mark the recompile doomed);
        // re-enforced on the decoded summary below so a root republish between the two
        // reads can't slip past it.
        guard let manifestTierBudget = manifest.summary.tierBudgetRuleCount else {
            return (nil, "tier-budget-unrecorded")
        }
        guard FilterRuleBudget.fitsTierBudget(
            compiledTotal: manifestTierBudget,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            return (nil, "over-tier-budget")
        }

        guard FileManager.default.fileExists(atPath: store.preparedSnapshotURL.path) else {
            return (nil, "missing")
        }
        guard let prepared = loadPreparedSnapshot(from: store) else {
            return (nil, "decode-failed")
        }
        guard prepared.identity == manifest.snapshotIdentity,
              prepared.snapshot.generatedAt == manifest.generatedAt,
              prepared.summary == manifest.summary
        else {
            return (nil, "manifest-mismatch")
        }

        // Authority gate: the decoded prepared's OWN rule count, not the manifest's, so a
        // root republish between the two reads can never make an over-budget generation
        // resident (the 2x-resident jetsam the budget guard exists to prevent).
        let ruleCount = prepared.summary.blockRuleCount + prepared.summary.allowRuleCount + prepared.summary.guardrailRuleCount
        guard !FilterSnapshotMemoryBudget.exceedsBudget(ruleCount: ruleCount) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-over-budget", details: [
                "identity": prepared.identity.fingerprint,
                "ruleCount": "\(ruleCount)"
            ])
            return (nil, "over-budget")
        }
        // INV-TIER-1 authority gate on the decoded prepared's OWN recorded total, same
        // decoded-bytes rationale as the budget gate above (and the same unrecorded/over
        // split as the pre-gate).
        guard let decodedTierBudget = prepared.summary.tierBudgetRuleCount else {
            return (nil, "tier-budget-unrecorded")
        }
        guard FilterRuleBudget.fitsTierBudget(
            compiledTotal: decodedTierBudget,
            maxFilterRules: configuration.limits.maxFilterRules
        ) else {
            LavaSecDeviceDebugLog.append(component: "tunnel", event: "loadSnapshot-prepared-over-tier-budget", details: [
                "identity": prepared.identity.fingerprint,
                "tierBudgetRuleCount": "\(decodedTierBudget)",
                "maxFilterRules": "\(configuration.limits.maxFilterRules)"
            ])
            return (nil, "over-tier-budget")
        }

        guard prepared.canReuseForProtectionStartup(configuration: configuration, cachedCatalog: cachedCatalog) else {
            return (nil, "decoded-reuse-mismatch")
        }
        return (prepared, nil)
    }

    private func loadPreparedSnapshot(from store: FilterArtifactStore) -> PreparedFilterSnapshot? {
        guard let data = try? Data(contentsOf: store.preparedSnapshotURL) else {
            return nil
        }

        return try? JSONDecoder().decode(PreparedFilterSnapshot.self, from: data)
    }

    func loadCachedCatalogMetadata() -> BlocklistCatalog? {
        guard let catalogCacheURL else {
            return nil
        }

        return try? BlocklistCatalogSynchronizer(
            cacheDirectoryURL: catalogCacheURL
        ).loadCachedCatalogMetadata()
    }

    var catalogCacheURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(
            LavaSecAppGroup.catalogCacheDirectoryName,
            isDirectory: true
        )
    }

    // The tunnel's own last successful in-extension compile, retained by
    // StreamingCompactSnapshotCompiler at a stable path so a later cold start can
    // fast-resume from it when the app-published artifact store lags the cached
    // catalog. UR-48 field log: the app had not republished after a catalog rotation,
    // so EVERY tunnel start strict-missed both app stores (root manifest-missing,
    // resolved reuse:inputs), served the transient fail-closed bootstrap, and repeated
    // a ~7 s / 356k-rule recompile — the outage window #294 bounds and this removes.
    // Read-gated exactly like the app's stores (identity + budget + sync cap), so a
    // stale retained compile is rejected, never served. Lives under the catalog cache
    // dir — OUTSIDE the app-owned store/pointer layout, so app publishes and versioned
    // GC never race it — and is a FilterArtifactStore only to reuse compactSnapshotURL
    // naming and the shared read helpers (its manifest/prepared slots are never written).
    private static let tunnelCompiledArtifactDirectoryName = "tunnel-compiled-artifact"

    private var tunnelCompiledArtifactStore: FilterArtifactStore? {
        catalogCacheURL.map {
            FilterArtifactStore(directoryURL: $0.appendingPathComponent(
                Self.tunnelCompiledArtifactDirectoryName,
                isDirectory: true
            ))
        }
    }

    // Read-side accessor: nil until a compile has actually been retained, so devices
    // that never in-extension compile (the healthy fast-resume path) add no per-start
    // store-miss log lines or stat reads for a file that has never existed.
    func retainedTunnelCompiledArtifactStoreIfPresent() -> FilterArtifactStore? {
        guard let store = tunnelCompiledArtifactStore,
              FileManager.default.fileExists(atPath: store.compactSnapshotURL.path)
        else {
            return nil
        }
        return store
    }

    var configurationURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.configurationFilename)
    }

    var diagnosticsURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsFilename)
    }

    var dnsEventLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.dnsEventLogFilename)
    }

    var networkActivityLogURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.networkActivityLogFilename)
    }

    var diagnosticsControlURL: URL? {
        LavaSecAppGroup.containerURL?.appendingPathComponent(LavaSecAppGroup.diagnosticsControlFilename)
    }

    func modificationDate(for url: URL?) -> Date? {
        guard let url,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        else {
            return nil
        }

        return attributes[.modificationDate] as? Date
    }
}
