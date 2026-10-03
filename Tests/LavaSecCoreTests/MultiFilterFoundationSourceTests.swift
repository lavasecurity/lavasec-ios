import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Phase 0 (Foundation) guards. The multi-filter library must be byte-for-byte
/// today's single-filter behaviour at library size 1; these lock the load-bearing
/// wiring that keeps `configuration` and the library in lockstep, the migration, and
/// the widened artifact GC. Most are source-introspection because the app target
/// (`AppViewModel`) is not compiled by `swift test`; the model/limits asserts are
/// behavioural.
final class MultiFilterFoundationSourceTests: XCTestCase {

    // MARK: - Behavioural (LavaSecCore is compiled)

    func testMultiFilterIsPlusGatedAtTheLimitsLayer() {
        XCTAssertEqual(FeatureLimits.free.maxFilters, 3, "Free tier hosts up to three filters (Core / Balanced / Extra).")
        XCTAssertFalse(FeatureLimits.free.hasUnlimitedFilters, "Free tier is capped, not unlimited.")
        XCTAssertEqual(FeatureLimits.paid.maxFilters, 50, "Plus hosts up to fifty filters.")
        XCTAssertFalse(FeatureLimits.paid.hasUnlimitedFilters, "Plus is capped at 50, not unlimited.")
    }

    func testSeededDefaultsBuildThreeNamedFiltersWithChosenActive() {
        let lib = FilterLibrary.seededDefaults(active: .comprehensive)
        XCTAssertEqual(lib.filters.count, 3)
        XCTAssertEqual(lib.filters.map(\.name), ["Core", "Balanced", "Extra"],
                       "Seeded filters are named after the protection levels, in cumulative order.")
        XCTAssertEqual(lib.activeFilterID, OnboardingProtectionLevel.comprehensive.filterID,
                       "The chosen level is the active (loaded) filter.")
        XCTAssertEqual(lib.schemaVersion, FilterLibrary.currentSchemaVersion)
        // Each seeded filter carries its level's catalog-derived blocklist set.
        XCTAssertEqual(
            lib.filter(id: OnboardingProtectionLevel.balanced.filterID)?.enabledBlocklistIDs,
            OnboardingProtectionLevel.balanced.enabledBlocklistIDs()
        )
        // The default (no argument) loads Balanced — the recommended stop.
        XCTAssertEqual(FilterLibrary.seededDefaults().activeFilterID, OnboardingProtectionLevel.balanced.filterID)
        XCTAssertEqual(OnboardingProtectionLevel.comprehensive.displayName, "Extra")
    }

    func testGroupContainerNamesTheFilterLibraryFile() throws {
        let source = try readSource(.appGroup)
        XCTAssertTrue(source.contains(#"filterLibraryFilename = "filter-library.json""#))
    }

    // MARK: - Persistence boundary keeps the library in lockstep

    func testConfigOnlyPersistSyncsAndWritesTheLibrary() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func persistConfigurationOnly(",
            endingBefore: "private func syncActiveFilterFromConfiguration()"
        )
        XCTAssertTrue(block.contains("syncActiveFilterFromConfiguration()"),
                      "Config-only writes must mirror the active filter into the library.")
        XCTAssertTrue(block.contains("SharedFilterStatePersistence.writeConfigurationAndLibrary("),
                      "Config-only writes go through the shared writer (config + library together, one source of truth).")
    }

    func testSharedStatePersistSyncsRecordsTokenAndWritesLibrary() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "let didRewriteArtifacts = rewritesRuleArtifacts",
            endingBefore: "func persistConfigurationOnly("
        )
        XCTAssertTrue(block.contains("syncActiveFilterFromConfiguration()"))
        XCTAssertTrue(block.contains("SharedFilterStatePersistence.writeConfigurationAndLibrary("))
        // Only a real artifact rewrite records the compiled token (so GC keeps the
        // active filter's dir warm); a reuse/no-op publish must not mint a token.
        XCTAssertTrue(block.contains("if didRewriteArtifacts {"))
        XCTAssertTrue(block.contains("FilterArtifactStore.versionedToken(for: snapshotToPersist)"))
        XCTAssertTrue(block.contains("$0.lastCompiledToken = token"))
    }

    func testSyncActiveFilterClearsStaleTokenOnlyOnRealChange() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "private func syncActiveFilterFromConfiguration() {",
            endingBefore: "func persistFilterLibrary("
        )
        // No-op guard prevents @Published churn; a real change clears the now-stale token.
        XCTAssertTrue(block.contains("guard filter.applyFilterFields(from: configuration) else { return }"))
        XCTAssertTrue(block.contains("filter.lastCompiledToken = nil"))
        XCTAssertTrue(block.contains("library.update(filter)"))
        // A dangling active id is repaired (not silently skipped) so config & library
        // can never drift apart.
        XCTAssertTrue(block.contains("library = library.normalized()"))
    }

    // MARK: - Migration

    func testLaunchLoadMigratesLegacyConfigIntoOneDefaultFilter() throws {
        let source = try readAppViewModelSource()
        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "func loadPersistedConfiguration() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        XCTAssertTrue(loadBlock.contains("loadOrMigrateFilterLibrary()"),
                      "The launch load must always load/migrate the library.")

        let migrateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            // Include migration and generation reconciliation within the persistence concern.
            endingBefore: "// MARK: - Sudoku easter egg persistence"
        )
        XCTAssertTrue(migrateBlock.contains(".seededDefaults(active: .balanced)"),
                      "Absent/empty/old-schema library ⇒ seed the three default filters with Balanced active.")
        XCTAssertTrue(migrateBlock.contains("normalized.schemaVersion >= FilterLibrary.currentSchemaVersion"),
                      "A pre-three-defaults (older schema) library is reseeded to the three defaults, not kept.")
        // The migrated library is persisted via persistConfigurationOnly, NOT persistFilterLibrary:
        // a legacy config is generation 0, so a plain library write would stamp the migrated library
        // at the trusted generation-0 sentinel (Codex r23). persistConfigurationOnly bumps first. The
        // launch-time persists suppress the backup hook (it runs before the auto-backup flag loads,
        // so it would clear the marker without scheduling the upload — Codex r24).
        XCTAssertTrue(migrateBlock.contains("try? persistConfigurationOnly(schedulesAutomaticBackup: false)"),
                      "The migrated/reconciled library must persist at a bumped generation without the launch-time backup hook.")
        XCTAssertFalse(migrateBlock.contains("try? persistFilterLibrary()"),
                       "Migration must not write the library at generation 0 via a plain library write.")
        XCTAssertTrue(migrateBlock.contains("persisted.normalized()"),
                      "A loaded library must be invariant-repaired before use.")
        XCTAssertTrue(migrateBlock.contains("if normalized.isValid,"),
                      "Only an invariant-valid library is loaded; otherwise migrate fresh.")
        XCTAssertTrue(migrateBlock.contains("!normalized.lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration)"),
                      "A library that lost the two-file write race (stale stamp) is rejected in favour of the config.")
        XCTAssertTrue(migrateBlock.contains("mirrorActiveFilterIntoConfiguration()"),
                      "On load the library is authoritative — the active filter is mirrored INTO config.")
        // Accepting an on-disk library reconciles the two files onto one non-zero generation:
        // stale config under a newer library (r22), the generation-0 legacy sentinel (r21), or both 0
        // (r23). The helper bumps to max(config, library) and, in the foreground, rewrites both files.
        XCTAssertTrue(migrateBlock.contains("reconcileLoadedLibraryGenerationIfNeeded()"),
                      "Accepting a library must reconcile its generation against the config.")
        XCTAssertTrue(migrateBlock.contains("library.configurationGeneration != configuration.configurationGeneration")
                        && migrateBlock.contains("|| library.configurationGeneration == 0"),
                      "Reconcile when the generations differ OR the library is at the generation-0 sentinel.")
        XCTAssertTrue(migrateBlock.contains("configuration.configurationGeneration = max("),
                      "Reconcile must advance the in-memory generation to at least the library's so a headless publish aborts.")
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("persistFilterLibrary"))
    }

    // MARK: - GC widen

    func testArtifactPublishRetainsEveryFilterCompiledToken() throws {
        let appSource = try readAppViewModelSource()
        let publishBlock = try sourceBlock(
            in: appSource,
            startingAt: "func persistPreparedSnapshotArtifacts(",
            endingBefore: "private func retainedFilterArtifactTokens()"
        )
        XCTAssertTrue(publishBlock.contains("additionalRetainedTokens: retainedFilterArtifactTokens()"),
                      "Publish must pass the hosted filters' tokens so GC keeps them warm.")

        let retainBlock = try sourceBlock(
            in: appSource,
            startingAt: "private func retainedFilterArtifactTokens() -> [String] {",
            endingBefore: "func persistSharedState("
        )
        XCTAssertTrue(retainBlock.contains("filter.lastCompiledToken"),
                      "Retention is built from each hosted filter's compiled token.")
        XCTAssertTrue(retainBlock.contains("library.filter(id: activeID)?.lastCompiledToken"),
                      "The active filter's token leads the warm set (most likely switch-back).")

        // The core GC must actually fold the extra tokens into its retained set.
        let coreSource = try readSource(.filterSnapshotPreparationService)
        XCTAssertTrue(coreSource.contains("additionalRetainedTokens: [String] = []"),
                      "persistArtifacts must accept the extra retained tokens (default empty ⇒ today's behaviour).")
        XCTAssertTrue(coreSource.contains("+ additionalRetainedTokens"),
                      "The extra tokens must be unioned into collectVersionedGarbage's retained set.")
    }

    // MARK: - Phase 1: switch / create / delete (view-model)

    func testFilterSwitchConfigurationOwnershipIsExplicitAndComplete() throws {
        let source = try readAppViewModelSource()
        let configurationSource = try readSource(.appConfiguration)
        let filterPlanFields: Set<String> = [
            "enabledBlocklistIDs",
            "customBlocklists",
            "blockedDomains",
            "allowedDomains",
        ]
        let deviceGlobalFields: Set<String> = [
            "dnsPatchEnabled",
            "usesExplicitDNSTiers",
            "savedDNSResolutionSelections",
            "protectionEnabled",
            "resolverPresetID",
            "customResolverAddress",
            "customResolverSecondaryAddress",
            "customResolverName",
            "fallbackToDeviceDNS",
            "usesEncryptedDeviceDNSFallback",
            "fallbackResolverPresetID",
            "fallbackCustomResolverAddress",
            "fallbackCustomResolverSecondaryAddress",
            "fallbackCustomResolverName",
            "keepFilteringCounts",
            "keepDomainDiagnostics",
            "keepNetworkActivity",
            "keepLavaGuardProgress",
            "isPaid",
            "qaProbeSet",
            "lavaGuardUnlocks",
            "configurationGeneration",
            "chainedUpstreamEnabled",
            "wireGuardSetupEnabled",
            "chainedTierOneFallbackEnabled",
        ]
        let allFields = filterPlanFields.union(deviceGlobalFields)

        XCTAssertEqual(allFields.count, 29)
        XCTAssertEqual(filterPlanFields.intersection(deviceGlobalFields), [])
        let declaredFields = Set(
            configurationSource
                .split(separator: "\n")
                .compactMap { line -> String? in
                    let line = line.trimmingCharacters(in: .whitespaces)
                    guard line.hasPrefix("public var "), !line.contains("{") else { return nil }
                    return line
                        .dropFirst("public var ".count)
                        .split(separator: ":", maxSplits: 1)
                        .first
                        .map(String.init)
                }
        )
        XCTAssertEqual(declaredFields, allFields,
                       "Every AppConfiguration field must be classified as filter-plan or device-global")

        let merge = try sourceBlock(
            in: source,
            startingAt: "private func applyingFilterPlan(",
            endingBefore: "enum SwitchPublication")
        let mergeCode = sourceCodeOnly(merge)
        XCTAssertTrue(mergeCode.contains("var mergedConfiguration = liveConfiguration"))
        for field in filterPlanFields {
            XCTAssertTrue(
                mergeCode.contains("mergedConfiguration.\(field) = plannedConfiguration.\(field)"),
                "The switch must merge filter-plan field \(field)")
        }
        for field in deviceGlobalFields {
            XCTAssertFalse(
                mergeCode.contains("mergedConfiguration.\(field) ="),
                "The switch must preserve device-global field \(field) from the live configuration")
        }
        XCTAssertTrue(mergeCode.contains("return mergedConfiguration"))

        let publicationCheck = try sourceBlock(
            in: source,
            startingAt: "private func switchPublicationMatchesLiveConfiguration(",
            endingBefore: "enum SwitchPublication")
        let publicationCheckCode = sourceCodeOnly(publicationCheck)
        XCTAssertTrue(publicationCheckCode.contains("hasSameConfiguration(as: configuration)"))
        XCTAssertTrue(
            publicationCheckCode.contains("preparedSnapshot.snapshot.resolver == configuration.resolverPreset"),
            "The snapshot check must distinguish resolver selections sharing one transport")
        XCTAssertTrue(publicationCheckCode.contains("FilterRuleBudget.fitsTierBudget"))
        XCTAssertTrue(publicationCheckCode.contains("configuration.limits.maxFilterRules"))
    }

    func testSwitchCommitsOnlyAfterPrepareAndKeepsPreviousOnFailure() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "enum SwitchPublication"
        )
        // Refuses no-op / unknown / frozen targets (no-op + unknown via the shared FilterSwitchPlan).
        XCTAssertTrue(block.contains("FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library)"))
        XCTAssertTrue(block.contains("!isFilterFrozen(id)"))
        // Prepares (warm reuse OR cold compile) first; commits configuration + active id only after.
        let prepareIdx = try XCTUnwrap(block.range(of: "prepareSwitchPublication(")?.lowerBound)
        let commitIdx = try XCTUnwrap(block.range(of: "library.setActiveFilter(id: id)")?.lowerBound)
        XCTAssertLessThan(prepareIdx, commitIdx, "The switch must commit only after prepare/reuse succeeds.")
        XCTAssertTrue(block.contains("var switchConfiguration = applyingFilterPlan(from: nextConfiguration, onto: configuration)"))
        XCTAssertTrue(block.contains("while true"),
                      "The live merge must be rechecked after any snapshot rebuild await.")
        XCTAssertTrue(
            block.contains("switchPublicationMatchesLiveConfiguration(publication, configuration: switchConfiguration)"),
            "The prepared artifact must be checked against the live merged configuration.")
        XCTAssertTrue(
            block.contains("publication = .compiled(try await prepareFilterSnapshot(")
                && block.contains("for: switchConfiguration"),
            "A stale prepared artifact must be rebuilt from the live merged configuration.")
        XCTAssertTrue(
            block.contains("let captureDiagnosticFailureEvent: @Sendable () -> FocusSwitchDiagnosticEvent?")
                && block.components(separatedBy: "diagnosticFailureEvent: captureDiagnosticFailureEvent").count - 1 == 4,
            "Every prepare/rebuild/persist boundary must use the same lock-backed diagnostic capture.")
        XCTAssertTrue(
            block.contains("applyingCustomBlocklistHashes: prepared.customResult.sourceHashes"),
            "A rebuild must carry accepted custom-list hashes into the local filter plan.")
        XCTAssertEqual(
            block.components(separatedBy: "switchConfiguration = applyingFilterPlan(from: nextConfiguration, onto: configuration)").count - 1,
            2,
            "The local target must be refreshed after each snapshot rebuild await.")
        XCTAssertTrue(
            block.contains("try await persistSharedState(")
                && block.contains("preparedSnapshot: publication.preparedSnapshot"))
        let rebuildIdx = try XCTUnwrap(
            block.range(of: "for: switchConfiguration")?.lowerBound)
        let rebuildGateIdx = try XCTUnwrap(
            block.range(
                of: "guard configurationReplacementGate.isCurrent(switchToken) else {",
                range: rebuildIdx..<block.endIndex
            )?.lowerBound)
        let commitConfigurationIdx = try XCTUnwrap(
            block.range(of: "configuration = switchConfiguration", range: rebuildGateIdx..<block.endIndex)?.lowerBound)
        let rebuiltTargetGuardIdx = try XCTUnwrap(
            block.range(
                of: "guard let liveTarget = library.filter(id: id), !isFilterFrozen(id) else {",
                range: rebuildIdx..<block.endIndex
            )?.lowerBound)
        let unchangedTargetGuardIdx = try XCTUnwrap(
            block.range(
                of: "guard liveTarget.hasSameFilterScopedFields(as: target) else {",
                range: rebuiltTargetGuardIdx..<block.endIndex
            )?.lowerBound)
        XCTAssertLessThan(rebuildIdx, rebuildGateIdx,
                          "A rebuild await must be followed by a supersession check before commit.")
        XCTAssertLessThan(rebuildGateIdx, commitIdx,
                          "A superseded rebuild must bail before committing the switch.")
        XCTAssertLessThan(rebuildIdx, rebuiltTargetGuardIdx,
                          "The target must be revalidated after the final snapshot rebuild.")
        XCTAssertLessThan(rebuiltTargetGuardIdx, commitConfigurationIdx,
                          "A deleted or frozen target must bail before the commit configuration is installed.")
        XCTAssertLessThan(rebuiltTargetGuardIdx, unchangedTargetGuardIdx)
        XCTAssertLessThan(unchangedTargetGuardIdx, commitConfigurationIdx,
                          "A target edited during preparation must bail before the stale prepared plan commits.")
        XCTAssertLessThan(rebuildGateIdx, commitConfigurationIdx,
                          "The target configuration must stay local until rebuild ownership is confirmed.")
        // Derived rule caches (applyCatalogSyncResult / applyReusablePreparedSnapshot) are applied only
        // AFTER the throwing persist, so a failed switch never leaves them describing the target (the
        // rollback can't restore them).
        let persistIdx = try XCTUnwrap(block.range(of: "try await persistSharedState(")?.lowerBound)
        let applyCatalogIdx = try XCTUnwrap(block.range(of: "applyCatalogSyncResult(prepared.catalogResult)")?.lowerBound)
        // GUARDED, NOT ASSERTED. `XCTAssertLessThan` is non-fatal and execution continues, so the
        // `block[persistIdx..<applyCatalogIdx]` below traps if the two calls are ever reordered —
        // and a trap kills the xctest process, so the whole bundle reports nothing instead of this
        // one test going red (Codex P2, PR #605).
        guard persistIdx < applyCatalogIdx else {
            return XCTFail(
                "Derived catalog/rule state must be applied only after the switch persists.")
        }
        // persistSharedState ends in an artifact-actor await; a superseded switch must re-check the
        // gate AFTER it, before the derived-cache tail, or it desyncs caches vs the newer owner's config.
        let postPersistRegion = String(block[persistIdx..<applyCatalogIdx])
        XCTAssertTrue(postPersistRegion.contains("guard configurationReplacementGate.isCurrent(switchToken) else {"),
                      "The switch must re-check the gate after the persist await, before applyCatalogSyncResult.")
        // Per-filter drafts: a switch no longer discards the previously-active filter's draft
        // (it lives under its own key and can't misattribute), it just drops the detail target.
        let successPart = String(block[..<(block.range(of: "} catch {")?.lowerBound ?? block.endIndex)])
        XCTAssertTrue(successPart.contains("filterEditTargetID = nil"))
        XCTAssertFalse(successPart.contains("filterEditDraft = nil"),
                       "Per-filter: a switch must NOT clear the previous filter's draft.")
        let detailTargetClearIdx = try XCTUnwrap(successPart.range(of: "filterEditTargetID = nil")?.lowerBound)
        let tunnelNotifyIdx = try XCTUnwrap(successPart.range(of: "await notifyTunnelSnapshotUpdated()")?.lowerBound)
        XCTAssertLessThan(
            detailTargetClearIdx, tunnelNotifyIdx,
            "Once the switch is durably published, the editor must stop routing the new active filter through the non-active save path before notify/restore can suspend.")
        // Overlapping switches AND switch-vs-restore/import are serialized by the shared
        // configuration-replacement gate: the attempt claims a token and bails before committing
        // if a newer replacement superseded it. Cover ownership follows presentsPreparationCover —
        // a user switch owns the cover; a silent Focus reconcile apply does not.
        XCTAssertTrue(block.contains("let switchToken = configurationReplacementGate.begin(ownsPreparationCover: presentsPreparationCover)"))
        let supersedeCommitIdx = try XCTUnwrap(successPart.range(of: "guard configurationReplacementGate.isCurrent(switchToken) else {")?.lowerBound)
        let successCommitIdx = try XCTUnwrap(successPart.range(of: "library.setActiveFilter(id: id)")?.lowerBound)
        XCTAssertLessThan(supersedeCommitIdx, successCommitIdx, "A superseded switch must bail before committing.")
        // The target may have been deleted OR frozen (Plus lapsed) during the async prepare —
        // re-validate both before commit, and surface it as a NON-retryable failure (retrying a
        // gone/frozen target just re-fails) instead of silently dropping the cover.
        XCTAssertTrue(block.contains("guard let liveTarget = library.filter(id: id), !isFilterFrozen(id) else {"))
        let unavailableGuardIdx = try XCTUnwrap(successPart.range(of: "guard let liveTarget = library.filter(id: id), !isFilterFrozen(id) else {")?.upperBound)
        let unavailableBody = String(successPart[unavailableGuardIdx...])
        XCTAssertTrue(unavailableBody.contains("filterPreparationFailureIsRetryable = false"),
                      "A deleted/frozen target must surface a non-retryable failure.")
        let changedTargetGuardIdx = try XCTUnwrap(
            successPart.range(of: "guard liveTarget.hasSameFilterScopedFields(as: target) else {")?.upperBound)
        let changedTargetBody = String(successPart[changedTargetGuardIdx...])
        XCTAssertTrue(changedTargetBody.contains("filterPreparationFailureIsRetryable = true"),
                      "An edited target must stay retryable so a fresh attempt prepares its new fields.")
        XCTAssertTrue(changedTargetBody.contains("That filter changed while it was being prepared. Try again."))
        // The switch records a retry target so the failure screen's Try Again retries it.
        XCTAssertTrue(block.contains("pendingSwitchFilterID = id"))
        // On failure: a .failed state, and the previously-loaded filter is RESTORED
        // exactly (rollback) — never the half-applied target.
        let catchStart = try XCTUnwrap(block.range(of: "} catch {")?.upperBound)
        let catchBlock = String(block[catchStart...])
        // A superseded failed switch must not roll back over a newer replacement that committed.
        XCTAssertTrue(catchBlock.contains("guard configurationReplacementGate.isCurrent(switchToken) else {"),
                      "The rollback path must also gate on the replacement token.")
        XCTAssertTrue(catchBlock.contains("filterPreparationState = .failed("))
        XCTAssertTrue(
            catchBlock.contains("configuration = applyingFilterPlan(from: previousConfiguration, onto: configuration)"),
            "Failure must roll only the filter plan back onto the live configuration.")
        XCTAssertTrue(catchBlock.contains("library.setActiveFilter(id: previousActiveID)"),
                      "Failure must roll the active id back to the previously-loaded filter.")
        XCTAssertTrue(catchBlock.contains("try? persistConfigurationOnly(rejectsAdvancedBeyond: rollbackGeneration)"),
                      "A post-write rollback must persist without overwriting a newer cross-process commit.")
        let switchCode = sourceCodeOnly(block)
        XCTAssertFalse(switchCode.contains("configuration = nextConfiguration"),
                       "Success must not install the stale whole configuration.")
        XCTAssertFalse(switchCode.contains("configuration = previousConfiguration"),
                       "Failure must not install the stale whole configuration.")
        XCTAssertFalse(catchBlock.contains("setActiveFilter(id: id)"), "Failure must not commit the target active id.")
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("filterEditDraft"))
    }

    /// Instant switch-back: a switch reuses the target filter's still-warm compiled artifacts (a
    /// pointer flip) when valid, and only cold-compiles on a miss — without ever serving stale rules.
    func testSwitchReusesWarmArtifactBeforeCompiling() throws {
        let source = try readAppViewModelSource()

        // prepareSwitchPublication: try warm reuse FIRST (gated on the target's lastCompiledToken),
        // fall back to the cold prepareFilterSnapshot on a miss.
        let prepareBlock = try sourceBlock(
            in: source,
            startingAt: "private func prepareSwitchPublication(",
            endingBefore: "func warmReusableSnapshotForSwitch("
        )
        // Try the shared warm-reuse helper FIRST, fall back to the cold prepareFilterSnapshot on a miss.
        let warmIdx = try XCTUnwrap(prepareBlock.range(of: "warmReusableSnapshotForSwitch(target: target")?.lowerBound)
        let coldIdx = try XCTUnwrap(prepareBlock.range(of: "try await prepareFilterSnapshot(")?.lowerBound)
        XCTAssertLessThan(warmIdx, coldIdx, "Warm reuse must be attempted before a cold compile.")
        // Warm reuse is skipped while a catalog sync is in flight — the quiescence gate that makes the
        // warm fast path mutually exclusive with syncs (it bails to a cold compile, which coalesces
        // with / follows the sync) so a warm flip can never race a refresh's recompile/republish.
        XCTAssertTrue(prepareBlock.contains("!catalog.isSyncInFlight"),
                      "Warm reuse must be skipped while a catalog sync is in flight (bail to cold).")
        XCTAssertTrue(prepareBlock.contains("return .warm(reusable)"))
        XCTAssertTrue(prepareBlock.contains("return .compiled(prepared)"))

        // The shared candidate loop (used by the foreground switch AND the headless warm switch): try
        // the library token + the sidecar token, each validated by the per-token loader.
        let warmCandidateBlock = try sourceBlock(
            in: source,
            startingAt: "func warmReusableSnapshotForSwitch(",
            endingBefore: "private func loadReusableWarmSnapshotForSwitch("
        )
        XCTAssertTrue(warmCandidateBlock.contains("target.lastCompiledToken"),
                      "Warm reuse is gated on the target's recorded compiled token.")
        XCTAssertTrue(warmCandidateBlock.contains("loadReusableWarmSnapshotForSwitch(token: token"),
                      "Each candidate token is validated by the per-token loader.")

        // The app's per-token loader delegates to the SHARED LavaSecCore validation core
        // (WarmFilterSnapshotLoader) so the foreground switch and the headless Focus engine can never
        // drift on reuse safety (LAV-100 Phase 4).
        let appLoadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadReusableWarmSnapshotForSwitch(",
            endingBefore: "func duplicateName(of name: String)"
        )
        XCTAssertTrue(appLoadBlock.contains("WarmFilterSnapshotLoader.loadReusable("),
                      "The app loader must delegate to the shared core validator, not reimplement reuse safety.")

        // WarmFilterSnapshotLoader.loadReusable (LavaSecCore): the load-bearing safety. It validates the
        // warm token's manifest + decoded snapshot against the TARGET's current configuration + cached
        // catalog (same checks as warm-startup reuse), and requires the snapshot to hash back to the
        // directory it came from so the later pointer flip targets exactly the validated dir.
        let loader = try readSource(.warmFilterSnapshotLoader)
        let loadBlock = try sourceBlock(
            in: loader,
            startingAt: "public static func loadReusable(",
            endingBefore: "package static func stillReusableAgainstCachedCatalog("
        )
        XCTAssertTrue(loadBlock.contains("versionedDirectoryURL(token: token)"),
                      "Reuse must read the target's specific token directory, not the live pointer.")
        XCTAssertTrue(loadBlock.contains("manifest.reuseRejectionReason(configuration: configuration, cachedCatalog: cachedCatalog) == nil"),
                      "Manifest-level reuse validation (coverage + source hashes + catalog version + resolver).")
        XCTAssertTrue(loadBlock.contains("preparedSnapshot.canReuseForProtectionStartup("),
                      "The decoded snapshot stays the authoritative reuse check.")
        XCTAssertTrue(loadBlock.contains("FilterArtifactStore.versionedToken(for: preparedSnapshot) == token"),
                      "The decoded snapshot must hash to its directory, so the pointer flip targets the validated dir.")
        // Reuse additionally requires a FRESH cached catalog (mirroring warmFilterArtifact's own
        // precondition). The identity check above accepts an artifact built from a stale cache, so
        // without this a token warmed while fresh could pointer-flip to a stale-catalog artifact long
        // after — instead of the cold path, which network-first refreshes when the cache is stale (r8).
        XCTAssertTrue(loadBlock.contains("hasFreshCachedCatalog(in: cacheURL, maxAge: freshnessMaxAge)"),
                      "Warm reuse must require a fresh cached catalog, falling back to the network-first cold path when stale.")
        // The warm path must enforce the SAME tier rule-limit gate as the cold compile, or a lapsed
        // Plus user could pointer-flip back to an oversized filter and bypass the free-tier cap. It
        // uses the budget total the cold gate persisted (summary.tierBudgetRuleCount), since the
        // per-field summary counts can't reconstruct it exactly; a legacy artifact without it falls
        // back to a cold compile. The comparison itself is the shared INV-TIER-1 gate
        // (FilterRuleBudget.fitsTierBudget — nil-recorded fails closed), one definition for the
        // warm switch, startup reuse, and every publish veto.
        XCTAssertTrue(loadBlock.contains("recordedTotal: preparedSnapshot.summary.tierBudgetRuleCount"),
                      "Warm reuse uses the persisted cold-gate budget total, not a re-derived count.")
        XCTAssertTrue(loadBlock.contains("FilterRuleBudget.fitsTierBudget("),
                      "Warm reuse must reject a filter exceeding the tier rule limit (shared INV-TIER-1 gate) and fall back to cold compile.")
        XCTAssertTrue(loadBlock.contains("maxFilterRules: configuration.limits.maxFilterRules"),
                      "The warm gate binds against the CURRENT tier's limit, so a lapse invalidates oversized reuse.")
        // The warm switch must hydrate the FULL guardrail (the snapshot carries only the
        // allowlist-overlap subset), or AllowlistValidator could allow a threat domain after a switch.
        XCTAssertTrue(loadBlock.contains("loadCached(enabledSourceIDs: [], includesGuardrails: true)"),
                      "Warm switch must hydrate the full guardrail (guardrail-only cache load).")
        XCTAssertTrue(loadBlock.contains("fullThreatGuardrail: fullThreatGuardrail"),
                      "The hydrated full guardrail must be carried to the apply step.")
        // ...and the app's OWN snapshot builders (which record lastCompiledToken on every in-place edit
        // / background publish) must populate that budget too, or a warm switch-back to a freshly
        // persisted token would ALWAYS fail the tier gate and cold-compile, defeating the feature for
        // the common case (Codex #133). Mirror the cold formula: block-merge + FULL guardrail (not the
        // snapshot's allowlist-overlap subset) + allowed + blocked.
        for builder in ["private func preparedSummary(for snapshot: FilterSnapshot)",
                        "nonisolated static func buildBackgroundPreparedSnapshot("] {
            let builderBlock = try sourceBlock(in: source, startingAt: builder, endingBefore: "\n    private func ")
            XCTAssertTrue(builderBlock.contains("tierBudgetRuleCount: blocklistRuleCount.map {")
                            && builderBlock.contains("$0 + threatGuardrail.count + configuration.allowedDomains.count + configuration.blockedDomains.count"),
                          "\(builder) must populate tierBudgetRuleCount with the cold-gate formula so warm reuse isn't always rejected.")
        }
        XCTAssertTrue(source.contains("threatGuardrail = reusable.fullThreatGuardrail ?? reusable.preparedSnapshot.snapshot.nonAllowableThreatRules"),
                      "Apply must use the full guardrail when present, falling back to the subset only for startup reuse.")

        // The shared switch tail applies the reused snapshot's already-compiled rules + catalog the
        // same way the warm-startup path does, and only a compiled publish updates the source hashes.
        let switchBlock = try sourceBlock(
            in: source,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "enum SwitchPublication"
        )
        XCTAssertTrue(switchBlock.contains("applyReusablePreparedSnapshot(reusable)"),
                      "A warm reuse applies the reused snapshot's derived state.")
        XCTAssertTrue(switchBlock.contains("if case .compiled(let prepared) = publication {"),
                      "Only a cold compile updates the app's per-source hash tracking.")
        // A warm reuse leaves the per-source rule-set caches stale (it reused the published artifact),
        // so it schedules a background rehydration so a later edit doesn't rebuild from the wrong
        // filter's caches. Cache-only + superseded-checked, never re-publishing (Codex #133 r4).
        XCTAssertTrue(switchBlock.contains("rehydrateRuleSetCachesAfterWarmSwitch("),
                      "A warm switch must schedule a background per-source cache rehydration.")
        // A catalog sync that ran while a warm switch prepares (the reuse load + holds suspend the main
        // actor) would race the warm flip. The pre-commit gate bails warm→cold on EITHER signal: a sync
        // is in flight RIGHT NOW (liveness), OR the live catalog no longer matches the one the warm
        // snapshot was validated against (content — a sync that started AND finished between the entry
        // gate and here leaves the controller idle yet moved the catalog; liveness alone can't see it).
        XCTAssertTrue(switchBlock.contains("if case .warm(let reusable) = publication {"),
                      "The pre-commit gate must bind the reused snapshot to compute catalog movement.")
        XCTAssertTrue(switchBlock.contains("if catalog.isSyncInFlight || catalogMovedSinceValidation {"),
                      "A warm reuse must bail to cold on a live sync OR a catalog that moved since validation.")
        // The content check is by per-source identity, not the catalog_version string, so a source
        // rotation that keeps catalog_version constant is still caught.
        XCTAssertTrue(switchBlock.contains("reusable.preparedSnapshot.identity.snapshotInputMismatches("),
                      "Catalog movement is detected by snapshot-input identity (per-source hashes).")
        XCTAssertTrue(switchBlock.contains("publication = .compiled(try await prepareFilterSnapshot(")
                        && switchBlock.contains("for: nextConfiguration"),
                      "...recompiling cold against the now-current catalog rather than publishing a stale warm flip.")
        // Post-persist: the .warm branch guards the apply against a sync that moved the catalog while
        // persistSharedState was suspended — applyReusablePreparedSnapshot would otherwise roll
        // currentCatalog/blockRules back over that sync's fresh state and wedge the rehydration gate.
        // It SKIPS the apply (the sync owns the fresh state) rather than rolling back; it must NOT
        // inline-recompile (the heavy machinery the simplification removed).
        XCTAssertTrue(switchBlock.contains("let catalogMovedDuringPersist = currentCatalog.map {")
                        && switchBlock.contains("if !catalogMovedDuringPersist {"),
                      "The .warm post-persist branch must skip the reuse apply if a sync moved the catalog during the persist.")
        XCTAssertEqual(switchBlock.components(separatedBy: "try await persistSharedState(").count - 1, 1,
                       "The warm switch must publish once — no post-persist inline recompile/republish.")
        let rehydrateBlock = try sourceBlock(
            in: source,
            startingAt: "func rehydrateRuleSetCachesAfterWarmSwitch(",
            endingBefore: "func duplicateName(of name: String)"
        )
        XCTAssertTrue(rehydrateBlock.contains("loadCached(enabledSourceIDs: enabledIDs)"),
                      "Rehydration loads the now-active filter's enabled source rule sets from cache.")
        XCTAssertTrue(rehydrateBlock.contains("configurationReplacementGate.isCurrent(switchToken)"),
                      "Rehydration must bail if a newer replacement superseded the warm switch.")
        XCTAssertTrue(rehydrateBlock.contains("configuration.enabledBlocklistIDs == enabledIDs")
                        && rehydrateBlock.contains("enabledCustomBlocklists(in: configuration) == customSources"),
                      "Rehydration must re-check the captured inputs (an in-place edit doesn't advance the token).")
        XCTAssertTrue(rehydrateBlock.contains("results.0.catalog == currentCatalog"),
                      "Rehydration must re-check the catalog by CONTENT (loaded == live), catching a source rotation a completed sync produced.")
        XCTAssertTrue(rehydrateBlock.contains("applySyncResults(catalogResult:"),
                      "Rehydration applies the loaded rule sets to the per-source caches.")
        XCTAssertFalse(rehydrateBlock.contains("persistSharedState") || rehydrateBlock.contains("writeArtifactPointer"),
                       "Rehydration must NOT re-publish artifacts — the pointer already names the warm dir.")
        // A rehydration that can't load the caches (rare disk error) self-heals via an authoritative
        // sync so the pending-edit gate doesn't stick.
        XCTAssertTrue(rehydrateBlock.contains("await syncCatalog()"),
                      "Rehydration must fall back to a catalog sync if the cache load fails, so the edit gate self-heals.")

        // Warm-switch cache gate (Codex #133): a warm switch leaves cachedBlockRuleSets describing the
        // PREVIOUS filter, so in-place blocklist edits must be deferred until the rehydration lands or
        // they'd rebuild + publish the target filter from the wrong filter's rule sets. The flag is set
        // in the .warm branch and cleared at the single fresh-cache chokepoint (applyCatalogSyncResult).
        XCTAssertTrue(switchBlock.contains("hasPendingWarmSwitchCacheRehydration = true"),
                      "The warm switch must mark the per-source caches pending so in-place edits defer.")
        let applyResultBlock = try sourceBlock(
            in: source,
            startingAt: "func applyCatalogSyncResult(",
            endingBefore: "func loadCachedCatalogAfterSyncFailure("
        )
        XCTAssertTrue(applyResultBlock.contains("cachedBlockRuleSets = result.sourceRuleSets")
                        && applyResultBlock.contains("hasPendingWarmSwitchCacheRehydration = false"),
                      "Loading fresh per-source caches must clear the warm-switch edit gate.")
        // Every in-place blocklist edit checks the gate and refuses while pending.
        XCTAssertTrue(source.contains("private func deferralReasonForInPlaceBlocklistEdit() -> String? {")
                        && source.contains("guard hasPendingWarmSwitchCacheRehydration else { return nil }"),
                      "A shared helper reports when in-place blocklist edits must be deferred.")
        for method in ["func toggleBlocklist(", "func addCustomBlocklist(", "func removeCustomBlocklist("] {
            let editBlock = try sourceBlock(in: source, startingAt: method, endingBefore: "\n    func ")
            XCTAssertTrue(editBlock.contains("deferralReasonForInPlaceBlocklistEdit()"),
                          "\(method) must defer while a warm-switch cache rehydration is pending.")
        }
        // restoreFiltersToDefault supersedes the warm switch and rebuilds + sync-fills its own
        // coverage, so it must clear the pending flag (the superseded rehydration bails without
        // clearing) — else a warm switch whose target was fully cached would wedge the flag.
        let restoreDefaultBlock = try sourceBlock(
            in: source,
            startingAt: "func restoreFiltersToDefault() {",
            endingBefore: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {"
        )
        XCTAssertTrue(restoreDefaultBlock.contains("hasPendingWarmSwitchCacheRehydration = false"),
                      "restoreFiltersToDefault must clear the warm-switch cache gate it supersedes.")

        // warmFilterArtifact must re-validate BOTH the filter fields AND the catalog after its compile
        // await, before stamping lastCompiledToken. A sync that moved the cache mid-compile would
        // otherwise stamp a token built from the previous catalog that warm reuse later rejects — the
        // filter would look warm yet cold-compile on its next switch. It stamps only a token the switch
        // reuse gate would honor NOW: the SAME canReuseForProtectionStartup check, against a freshly
        // re-read cached catalog (Codex r12).
        let warmBlock = try sourceBlock(
            in: source,
            startingAt: "func warmFilterArtifact(forFilterID",
            endingBefore: "func reconcileWarmNonActiveFilters("
        )
        // A background warm must stay read-only w.r.t. the shared catalog cache: it skips when a
        // low-risk launch migration is pending (prepareFilterSnapshot's migrate can purge latest.json
        // expecting a sync the cache-only warm never runs), letting the normal refresh path handle it
        // and reconcile re-warm afterward (Codex r15).
        XCTAssertTrue(warmBlock.contains("cachedCatalogRequiresLowRiskLaunchRefresh("),
                      "Warm must skip when a low-risk launch migration is pending (stay read-only w.r.t. the cache).")
        XCTAssertTrue(warmBlock.contains("current.enabledBlocklistIDs == compiledEnabled"),
                      "Warm must re-check the filter fields it compiled before stamping the token.")
        XCTAssertTrue(warmBlock.contains("loadCachedCatalogMetadata()")
                        && warmBlock.contains("prepared.snapshot.canReuseForProtectionStartup("),
                      "Warm must re-validate the catalog (canReuseForProtectionStartup vs the re-read cache) before stamping, so a sync that moved the catalog mid-compile can't stamp a token reuse rejects.")
        XCTAssertTrue(warmBlock.contains("lastCompiledToken = result.token"),
                      "Warm stamps the shared core's compiled token only after both re-validations pass.")
        XCTAssertTrue(warmBlock.contains("await compileAndStageWarmArtifact(forFilterID:"),
                      "Foreground warm delegates compile+stage+revalidate to the shared core (also used by the background sidecar path).")
        XCTAssertTrue(warmBlock.contains("if Task.isCancelled { return nil }"),
                      "The shared warm core must bail before staging if the BGTask deadline passed during the compile await (Codex #138 r3).")
        // Repeated warms of the same filter mint fresh generatedAt tokens and overwrite
        // lastCompiledToken; stageArtifacts never GCs, so warm must reclaim the prior orphaned dir
        // after a successful stamp or disk grows past the filter cap in edit-heavy sessions (Codex r14).
        XCTAssertTrue(warmBlock.contains("collectWarmArtifactGarbage(")
                        && warmBlock.contains("retaining: retainedFilterArtifactTokens()"),
                      "Warm must reclaim orphaned artifact dirs after stamping, retaining every hosted token.")
    }

    /// Phase 2 sidecar warm-index wiring: the BACKGROUND BGTask warms non-active filters into the
    /// sidecar (never the library), the foreground READS the sidecar (switch read-fallback + GC union)
    /// and PROMOTES valid entries into the library. The load-bearing safety invariant is that the
    /// background warm loop never writes filter-library.json / app-configuration.json.
    func testBackgroundWarmIndexSidecarWiring() throws {
        let source = try readAppViewModelSource()

        // Switch read-fallback: try BOTH the library token and the sidecar token (validated
        // identically). A non-nil-but-STALE library token must not block the fresh sidecar one
        // (Codex #138) — so it's a two-candidate try, not a plain ?? that picks only one.
        XCTAssertTrue(source.contains("loadBackgroundWarmIndex().token(forFilterID: target.id)"),
                      "A switch must consider the sidecar token.")
        XCTAssertTrue(source.contains("sidecarToken != target.lastCompiledToken"),
                      "A switch must try the sidecar token even when the library token is non-nil (stale), deduping only an identical token.")

        // GC union: background-warmed dirs are referenced only by the sidecar until promotion, so the
        // retain set must include them — but ONLY for filters that still exist and are switchable, or a
        // deleted/frozen filter's dir leaks until a BGTask rewrites the sidecar (Codex #138 r5).
        XCTAssertTrue(source.contains("loadBackgroundWarmIndex().entries")
                        && source.contains("library.filter(id: filterID) != nil && !isFilterFrozen(filterID)"),
                      "retainedFilterArtifactTokens must retain sidecar tokens only for current, switchable filters.")

        // The background warm pass runs ONLY on bg-published — the one outcome that committed the fresh
        // catalog to latest.json. bg-unchanged does NOT qualify (latest.json not committed; sync may have
        // used cache or fetched non-active changes), nor do aborted outcomes (Codex #138 r6 P1).
        XCTAssertTrue(source.contains("actionStatus == \"bg-published\""),
                      "Background warming must be gated on bg-published (catalog committed to latest.json).")
        XCTAssertFalse(source.contains("touchCachedCatalogFreshness"),
                       "The freshness touch is removed — latest.json is only trustworthy-current on a commit, which already refreshes its mtime (Codex #138 r6 P1).")

        // Promotion: reconcile promotes a valid sidecar token into the library instead of recompiling.
        let reconcileBlock = try sourceBlock(
            in: source,
            startingAt: "func reconcileWarmNonActiveFilters(",
            endingBefore: "/// Promote a sidecar"
        )
        XCTAssertTrue(reconcileBlock.contains("warmIndex.token(forFilterID:"),
                      "Reconcile must consider a sidecar token before recompiling.")
        XCTAssertTrue(reconcileBlock.contains("promoteWarmTokenIntoLibrary("),
                      "Reconcile must promote a valid sidecar token into the library.")
        // A trigger that arrives while a pass is in flight (e.g. a catalog apply) must QUEUE a rerun, not be
        // dropped — else the non-active filters stay stale and a closed-app Focus switch to them defers-to-cold
        // instead of warm (Codex P2). Mirrors reconcilePendingFilterSwitch's pendingReconcileRerun.
        XCTAssertTrue(reconcileBlock.contains("pendingWarmReconcileRerun = true"),
                      "An overlapping warm-reconcile trigger must queue a rerun, not drop the pass.")
        XCTAssertTrue(reconcileBlock.contains("await reconcileWarmNonActiveFiltersOnce()"),
                      "The wrapper must drain via the single-pass method in a rerun loop.")
        let promoteBlock = try sourceBlock(
            in: source,
            startingAt: "private func promoteWarmTokenIntoLibrary(",
            endingBefore: "func warmNonActiveFiltersInBackground("
        )
        XCTAssertTrue(promoteBlock.contains("persistLibraryOnlyChange(rollingBackTo:"),
                      "Promotion is a foreground library-only write.")

        // The background warm loop is wired into the BGTask refresh, after the active publish.
        XCTAssertTrue(source.contains("await warmNonActiveFiltersInBackground(window: .processing)"),
                      "The background refresh must warm non-active filters after publishing the active one, "
                        + "in the LONG window: the fetch window's admission and contention policies would "
                        + "make the post-publish pass hand itself away or skip large filters (PR #646).")

        // Anchored on the UNDER-LOCK pass, not the single-flight wrapper that now precedes it — the
        // assertions below are about the loop, and the wrapper would make the block a superset that
        // happens to satisfy them (PR #646).
        let bgBlock = try sourceBlock(
            in: source,
            startingAt: "private func warmNonActiveFiltersInBackgroundUnderLock(",
            endingBefore: "static var isWarmPassInFlight"
        )
        XCTAssertTrue(bgBlock.contains("guard isHeadless"),
                      "The background warm loop runs only headless (the foreground uses the library path).")
        XCTAssertTrue(bgBlock.contains("compileAndStageWarmArtifact(forFilterID:"),
                      "The background warm loop reuses the shared compile+stage+revalidate core.")
        XCTAssertTrue(bgBlock.contains("store.save("),
                      "The background warm loop records warmed filters in the sidecar (its only write).")
        XCTAssertTrue(bgBlock.contains("configuration.limits.maxFilterRules"),
                      "The per-run budget must be sized to the user's TIER, not the free ceiling, or Plus-sized filters never background-warm (panel finding).")
        XCTAssertTrue(bgBlock.contains("window.admitsCandidate("),
                      "Admission is the WINDOW's decision now: the long window still caps the over-counting "
                        + "estimate at the budget so its coldest candidate always fits (panel finding), but a "
                        + "fetch window must refuse an oversized candidate instead — admitting it first is what "
                        + "made the short window never finish a run (PR #646). BackgroundWarmPassWindowTests "
                        + "covers both behaviours.")
        XCTAssertEqual(bgBlock.components(separatedBy: "guard !Task.isCancelled else { return }").count - 1, 3,
                       "Every app-group-mutating path (empty-candidates save, post-loop save, pre-GC) must be deadline-guarded (panel findings).")
        XCTAssertTrue(bgBlock.contains("estimatedRuleCount(forFilterID:"),
                      "The per-run budget must be enforced via a PRE-compile estimate, so one oversized filter can't blow the cap (Codex #138 r4/r6).")
        XCTAssertTrue(bgBlock.contains("syncedAt(forFilterID:"),
                      "The background warm loop orders most-stale-first by the sidecar's last syncedAt.")
        XCTAssertTrue(bgBlock.contains("Task.isCancelled"),
                      "The background warm loop respects the BGTask deadline between filters.")
        XCTAssertTrue(bgBlock.contains("guard !Task.isCancelled else { return }"),
                      "The background warm loop must not rewrite the sidecar / GC past the BGTask deadline (Codex #138 r2).")
        XCTAssertTrue(bgBlock.contains("collectWarmArtifactGarbage("),
                      "The background warm loop runs one GC after the loop, retaining the sidecar set.")
        XCTAssertTrue(bgBlock.contains("persistedLibraryArtifactTokens()"),
                      "The background GC must also retain the CURRENT on-disk library tokens, so a foreground warm during the pass isn't reaped (Codex #138 r7).")
        // Load-bearing: the background must NEVER write the library or app-configuration.
        XCTAssertFalse(bgBlock.contains("persistLibraryOnlyChange") || bgBlock.contains("persistSharedState") || bgBlock.contains("persistConfigurationOnly"),
                       "The background warm loop must never write filter-library.json / app-configuration.json.")
    }

    /// A warm reuse flips the pointer to an OLD directory whose mtime the GC grace window no longer
    /// protects, so a concurrent publisher could reap it between the off-lock stage and the flip.
    /// persistArtifacts must re-stage UNDER the publish lock (re-materializing a reaped dir) before
    /// flipping, so the pointer never names a missing directory (Codex #133 r3).
    func testPublishReStagesUnderThePublishLockBeforeFlipping() throws {
        let service = try readSource(.filterSnapshotPreparationService)
        let flip = try sourceBlock(
            in: service,
            startingAt: "let flipUnderLock: () throws -> PublishOutcome = {",
            endingBefore: "switch lockMode {"
        )
        let supersedeIdx = try XCTUnwrap(flip.range(of: "supersededWhileLocked(previousToken)")?.lowerBound)
        let reStageIdx = try XCTUnwrap(flip.range(of: "artifactStore.stageVersionedArtifacts(preparedSnapshot: preparedSnapshot, writtenAt: writtenAt)")?.lowerBound)
        let flipIdx = try XCTUnwrap(flip.range(of: "writeArtifactPointer(pointer)")?.lowerBound)
        XCTAssertLessThan(supersedeIdx, reStageIdx, "Re-stage only after the supersession check passes.")
        XCTAssertLessThan(reStageIdx, flipIdx, "Re-stage (re-materialize a reaped dir) before flipping the pointer.")
    }

    /// All FOUR wholesale config+library replacers (switch, restore, import, draft-apply) must
    /// claim the shared gate before their first await and re-check it before committing AND before
    /// the post-persist (artifact-actor await) side-effect tail — otherwise a superseded replacer
    /// silently reverts a concurrent one or desyncs the rule caches.
    func testEveryWholesaleReplacerClaimsAndRechecksTheGate() throws {
        let app = try readAppViewModelSource()

        // Import: claims importToken, re-checks before commit AND after the persist (applyCatalogSyncResult
        // is deferred past the persist so a superseded import can't desync caches).
        let importBlock = try sourceBlock(
            in: app,
            startingAt: "func applyImportedShareableConfiguration(",
            endingBefore: "func retryFilterPreparation()"
        )
        XCTAssertTrue(importBlock.contains("let importToken = configurationReplacementGate.begin()"))
        let importPersistIdx = try XCTUnwrap(importBlock.range(of: "try await persistSharedState(preparedSnapshot: prepared.snapshot,")?.lowerBound)
        let importApplyIdx = try XCTUnwrap(importBlock.range(of: "applyCatalogSyncResult(prepared.catalogResult)")?.lowerBound)
        // GUARDED, NOT ASSERTED — the range below traps if these are ever reordered, and a
        // trap kills the whole test bundle rather than failing this test (Codex P2, PR #605).
        guard importPersistIdx < importApplyIdx else {
            return XCTFail("Import must defer derived-cache apply past the persist.")
        }
        XCTAssertTrue(String(importBlock[importPersistIdx..<importApplyIdx]).contains("guard configurationReplacementGate.isCurrent(importToken)"),
                      "Import must re-check the gate after the persist await, before its tail.")
        let importCommitIdx = try XCTUnwrap(importBlock.range(of: "configuration = nextConfiguration")?.lowerBound)
        let importPrecheckIdx = try XCTUnwrap(importBlock.range(of: "guard configurationReplacementGate.isCurrent(importToken)")?.lowerBound)
        XCTAssertLessThan(importPrecheckIdx, importCommitIdx, "Import must re-check the gate before committing.")

        // Draft apply: a fourth wholesale replacer — claims draftToken, re-checks before commit AND
        // after the persist, and resets the retryable flag so a prior dead-end switch can't leak.
        let draftBlock = try sourceBlock(
            in: app,
            startingAt: "func prepareAndApplyFilterDraft(origin: FilterReviewOrigin",
            endingBefore: "func isFilterFrozen("
        )
        XCTAssertTrue(draftBlock.contains("filterPreparationFailureIsRetryable = true"),
                      "A fresh draft apply must reset retryability so an edit failure still offers Try Again.")
        XCTAssertTrue(draftBlock.contains("let draftToken = configurationReplacementGate.begin(ownsPreparationCover: true)"))
        let draftCommitIdx = try XCTUnwrap(draftBlock.range(of: "configuration = nextConfiguration")?.lowerBound)
        let draftPrecheckIdx = try XCTUnwrap(draftBlock.range(of: "guard configurationReplacementGate.isCurrent(draftToken) else {")?.lowerBound)
        XCTAssertLessThan(draftPrecheckIdx, draftCommitIdx, "Draft apply must re-check the gate before committing.")
        let draftPersistIdx = try XCTUnwrap(draftBlock.range(of: "try await persistSharedState(preparedSnapshot: prepared.snapshot)")?.lowerBound)
        let draftApplyIdx = try XCTUnwrap(draftBlock.range(of: "applyCatalogSyncResult(prepared.catalogResult)")?.lowerBound)
        // GUARDED, NOT ASSERTED — the range below traps if these are ever reordered, and a
        // trap kills the whole test bundle rather than failing this test (Codex P2, PR #605).
        guard draftPersistIdx < draftApplyIdx else {
            return XCTFail("Draft apply must defer derived-cache apply past the persist.")
        }
        XCTAssertTrue(String(draftBlock[draftPersistIdx..<draftApplyIdx]).contains("guard configurationReplacementGate.isCurrent(draftToken) else {"),
                      "Draft apply must re-check the gate after the persist await, before its tail.")
        // The catch must ALSO re-check (like switchToFilter's catch): a superseded apply that throws
        // must not stomp the winner's preparation cover with a spurious .failed + haptic.
        let draftCatch = String(draftBlock[(try XCTUnwrap(draftBlock.range(of: "} catch {")?.upperBound))...])
        let draftCatchGuardIdx = try XCTUnwrap(draftCatch.range(of: "guard configurationReplacementGate.isCurrent(draftToken) else {")?.lowerBound)
        let draftCatchFailedIdx = try XCTUnwrap(draftCatch.range(of: "filterPreparationState = .failed(")?.lowerBound)
        XCTAssertLessThan(draftCatchGuardIdx, draftCatchFailedIdx,
                          "The draft-apply catch must bail when superseded before touching the shared cover.")

        // Cover-driving replacers claim the gate as cover owners so a superseded one knows to dismiss
        // its stranded spinner when a non-cover-driver (restore/import) supersedes it; restore/import
        // claim as non-owners (plain begin()). The draft apply ALWAYS owns the cover; the filter switch
        // owns it only for a genuine user switch — a silent Focus reconcile apply
        // (stampsForegroundSwitch:false ⇒ presentsPreparationCover == false) drives no cover.
        XCTAssertTrue(app.contains("configurationReplacementGate.begin(ownsPreparationCover: true)"),
                      "The draft apply must claim the gate as a preparation-cover owner.")
        XCTAssertEqual(app.components(separatedBy: "begin(ownsPreparationCover: true)").count - 1, 1,
                       "Only the draft apply owns the cover unconditionally.")
        XCTAssertEqual(app.components(separatedBy: "begin(ownsPreparationCover: presentsPreparationCover)").count - 1, 1,
                       "The filter switch claims cover ownership conditionally (silent for a Focus reconcile apply).")
        XCTAssertTrue(app.contains("func dismissPreparationCoverIfStrandedBySupersession()"),
                      "A superseded cover-driver dismisses its stranded cover via a shared helper.")
        XCTAssertTrue(app.contains("guard !configurationReplacementGate.currentOwnerOwnsPreparationCover else { return }"),
                      "The dismiss helper must no-op when the new owner is itself a cover-driver.")
        // Every supersession bail in the two cover-driving replacers routes through the helper. Each
        // path (switch / draft apply) bails at: commit + post-rebuild + post-persist + saving-top-before-tick +
        // render-yield-before-Success + success-hold + rollback/catch = 6 each. The three progress-bar
        // bails guard the shared cover against a newer preparation superseding us during the
        // notify/restore awaits, the 3/4-render yield, and the 1.2s success hold respectively (#284 P2).
        XCTAssertEqual(app.components(separatedBy: "dismissPreparationCoverIfStrandedBySupersession()").count - 1, 14,
                       "Thirteen supersession bails call the dismiss helper, plus its one definition.")

        // The retryable flag must ONLY be reset to true at the two fresh-attempt entry points
        // (switch + draft apply) — not scattered — and set false only on the dead-end edge. Total
        // The declaration default is now owned by FilterDraftController.
        XCTAssertEqual(app.components(separatedBy: "filterPreparationFailureIsRetryable = true").count - 1, 3,
                       "Retryability is enabled at the two fresh-attempt entry points and the target-changed retry exit.")
        XCTAssertTrue(try readSource(.filterDraftController).contains("@Published var preparationFailureIsRetryable = true"))
        XCTAssertEqual(app.components(separatedBy: "filterPreparationFailureIsRetryable = false").count - 1, 1,
                       "Retryability is cleared only on the single deleted/frozen dead-end edge.")
    }

    func testWarmArtifactRetentionKeepsEveryNonFrozenFilter() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "private func retainedFilterArtifactTokens() -> [String] {",
            endingBefore: "func warmFilterArtifact(forFilterID"
        )
        // Every non-frozen hosted filter stays warm so a switch to ANY of them (manual or a
        // Focus auto-switch) is an instant pointer flip — no artificial count cap.
        XCTAssertTrue(block.contains("!isFilterFrozen(filter.id)"),
                      "Frozen (read-only) filters are excluded from the warm set.")
        XCTAssertTrue(block.contains("filter.lastCompiledToken"),
                      "Retention is built from each non-frozen filter's compiled token.")
        XCTAssertFalse(source.contains("maxWarmFilterArtifacts"),
                       "The fixed warm-set cap was removed — keep every non-frozen filter warm.")
        XCTAssertFalse(block.contains("prefix("),
                       "No count cap truncating the warm set.")
    }

    func testCreateFilterIsPlusGatedAndLibraryOnly() throws {
        let source = try readAppViewModelSource()
        let block = try sourceBlock(
            in: source,
            startingAt: "func createFilter(name: String, duplicatingFilterID:",
            endingBefore: "func renameFilter(id: String"
        )
        XCTAssertTrue(block.contains("guard canCreateFilter else { return nil }"),
                      "Creating a filter must be gated on the tier filter cap.")
        XCTAssertTrue(block.contains("library.append(newFilter)"))
        // Anchored on what createFilter itself calls. This previously matched a bare
        // `persistFilterLibrary()` that lives in `persistLibraryOnlyChange` — which falls inside
        // this block's boundaries — so it passed without ever describing createFilter.
        XCTAssertTrue(block.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary)"))
        XCTAssertFalse(
            block.contains("try await persistSharedState("),
            "Creation is library-only: no config write, no publish."
        )
        // The new filter is warmed off the hot path (background Task) so a later switch is an
        // instant pointer flip; creation itself stays library-only and never republishes.
        XCTAssertTrue(block.contains("Task { await warmFilterArtifact(forFilterID: newID) }"),
                      "A new filter is warmed off the hot path for instant later switching.")
        XCTAssertFalse(block.contains("notifyTunnelSnapshotUpdated"),
                       "A new (non-active) filter must not republish / reload the live tunnel.")
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(source.contains("notifyTunnelSnapshotUpdated"))
    }

    func testDeleteFilterDelegatesToInvariantSafeRemoval() throws {
        let source = try readAppViewModelSource()
        let deleteBlock = try sourceBlock(
            in: source,
            startingAt: "func deleteFilter(id: String) -> Bool {",
            endingBefore: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {"
        )
        // library.remove refuses the active filter and the last remaining filter; the
        // model also enforces the read-only freeze (below the UI affordances).
        XCTAssertTrue(deleteBlock.contains("guard !isFilterFrozen(id)"),
                      "Delete must refuse a frozen (read-only) filter at the model layer.")
        XCTAssertTrue(deleteBlock.contains("library.remove(id: id)"),
                      "Delete must use the invariant-safe removal (refuses active / last).")

        // rename enforces the same model-level freeze.
        let renameBlock = try sourceBlock(
            in: source,
            startingAt: "func renameFilter(id: String, to name: String, emoji: String? = nil) -> Bool {",
            endingBefore: "func deleteFilter(id: String) -> Bool {"
        )
        XCTAssertTrue(renameBlock.contains("!isFilterFrozen(id)"),
                      "Rename must refuse a frozen (read-only) filter at the model layer.")
    }

    func testMigrationWriteIsSkippedForHeadlessRefreshAndRetryRoutesToSwitch() throws {
        let source = try readAppViewModelSource()
        // The headless background-refresh model must not persist the migration (read-only),
        // or it could overwrite a foreground-created library (read→write race).
        let migrateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            // Include migration and generation reconciliation within the persistence concern.
            endingBefore: "// MARK: - Sudoku easter egg persistence"
        )
        XCTAssertTrue(migrateBlock.contains("if !isHeadless {"),
                      "Migration persist must be gated to foreground (non-headless) instances.")
        XCTAssertTrue(source.contains("isHeadless = headless"), "init must capture the headless flag.")

        // The shared failure screen's Try Again retries a failed SWITCH (no draft), not a
        // no-op draft apply.
        let retryBlock = try sourceBlock(
            in: source,
            startingAt: "func retryFilterPreparation() {",
            endingBefore: "var tunnelCacheHitRateText"
        )
        XCTAssertTrue(retryBlock.contains("if let id = pendingSwitchFilterID {"))
        XCTAssertTrue(retryBlock.contains("await switchToFilter(id: id)"))
    }

    func testBackupIncludesLibraryAndOrdersPersistWritesByDurability() throws {
        let core = try readSource(.backupConfigurationPayload)
        XCTAssertTrue(core.contains("public let filterLibrary: FilterLibrary?"),
                      "The backup payload must carry the whole filter library.")
        XCTAssertTrue(core.contains("func restoredFilterLibrary() -> FilterLibrary?"))

        let app = try readAppViewModelSource()
        XCTAssertTrue(app.contains("filterLibrary: library"),
                      "Turn-on must seal the library into the payload.")
        XCTAssertTrue(app.contains("library = plan.library"),
                      "Restore must apply the reviewed authoritative library.")
        XCTAssertTrue(app.contains("func persistLibraryOnlyChange("),
                      "Library-only changes must schedule a backup, like config changes.")
        // A failed library-only write must roll the published library back to its pre-mutation
        // snapshot, so a change reported as failed isn't left live (or persisted later by config).
        let persistLibBlock = try sourceBlock(
            in: app,
            startingAt: "func persistLibraryOnlyChange(",
            endingBefore: "func renameFilter(id: String, to name: String, emoji: String? = nil)"
        )
        XCTAssertTrue(persistLibBlock.contains("library = previousLibrary"),
                      "A failed library-only write must roll back the in-memory library.")

        // The two files are each atomic but NOT transactional as a pair, so persistSharedState
        // orders them by which side is unreconstructable on a mid-write kill: normal edits persist
        // the library (source of truth) BEFORE config (derived cache); a RESTORE persists config
        // FIRST (prioritizesConfigurationDurability) because the config carries device-global
        // fields the library can't reconstruct.
        // The ordering now lives in the single shared writer (SharedFilterStatePersistence). Normal
        // edits persist the library (source of truth) BEFORE config (derived cache); a RESTORE
        // (prioritizesConfigurationDurability) persists the unreconstructable device-global config FIRST,
        // then the library — a kill before the config lands can't destroy existing filters (Codex r19);
        // a kill after it leaves a lower-generation library that load rejects (Codex r20). No destructive
        // pre-delete: the generation stamp, not file removal, invalidates a stale library.
        // The shared writer writes config exactly once; the library write moves to one side: a normal
        // edit's library write (in the `if !prioritizesConfigurationDurability` block, source-first)
        // precedes the config write; a restore's library write (in the `if prioritizes…` block,
        // source-last) follows it.
        let writer = try readSource(.sharedFilterStatePersistence)
        let cfgIdx = try XCTUnwrap(writer.range(of: "configurationData.write(to: configurationURL")?.lowerBound)
        let normalLibIdx = try XCTUnwrap(writer.range(of: "libraryData.write(to: filterLibraryURL")?.lowerBound)
        let restoreLibIdx = try XCTUnwrap(writer.range(of: "libraryData.write(to: filterLibraryURL", options: .backwards)?.lowerBound)
        XCTAssertLessThan(normalLibIdx, cfgIdx, "Normal edits must persist the library before the config it derives.")
        XCTAssertLessThan(cfgIdx, restoreLibIdx, "A config-durable (restore) persist must write the config before the library.")
        XCTAssertFalse(app.contains("removeFilterLibraryFile"),
                       "The generation marker replaces the destructive pre-delete on the restore path.")

        // The write-race generation marker: a library-only edit advances the shared generation via the pair
        // writer (persistFilterLibrary delegates to persistConfigurationOnly), and load rejects a library
        // whose stamp lost the race. Delegating — rather than an un-bumped library-only write — is what lets
        // a foreground edit trip the App Intents extension's stale-reader fence (Codex P1, state-agnostic
        // switch); the actual stamp is single-sourced in the shared writer (asserted below at lines ~813).
        let persistFilterLibraryBlock = try sourceBlock(
            in: app,
            startingAt: "func persistFilterLibrary(",
            // loadCustomizationPreferences moved to CustomizationController (Phase D5);
            // the next hub member after the library-only persist is the progress load.
            endingBefore: "func loadLavaGuardProgress()"
        )
        XCTAssertTrue(persistFilterLibraryBlock.contains("persistConfigurationOnly("),
                      "persistFilterLibrary must delegate to persistConfigurationOnly so a library-only edit bumps the shared generation (and the extension's fence can trip).")
        XCTAssertTrue(
            persistFilterLibraryBlock.contains("rejectsAdvancedBeyond: configuration.configurationGeneration"),
            "A foreground library-only write must fence against its loaded generation so it cannot overwrite a newer headless filter switch with a stale whole pair.")
        let loadBlock = try sourceBlock(
            in: app,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            // Include migration and generation reconciliation within the persistence concern.
            endingBefore: "// MARK: - Sudoku easter egg persistence"
        )
        XCTAssertTrue(loadBlock.contains("lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration)"),
                      "Load must reject a library that lost the two-file write race against the config.")
        // The shared writer bumps the generation monotonically (max of in-memory + on-disk) and stamps
        // the library to pair with the config — so the library it stamps and the config it writes always
        // carry the same (new) generation.
        XCTAssertTrue(writer.contains("max(configuration.configurationGeneration, onDiskConfigurationGeneration(at: configurationURL)) + 1"),
                      "The shared writer must bump the generation monotonically from the on-disk value (survives a restore reset).")
        XCTAssertTrue(writer.contains("nextLibrary.configurationGeneration = nextConfiguration.configurationGeneration"),
                      "The shared writer must stamp the library with the paired (bumped) config generation.")
    }

    func testBackupReSealsOnChangeAndRestoreIsLibraryAuthoritative() throws {
        let core = try readSource(.zeroKnowledgeBackupEnvelope)
        XCTAssertTrue(core.contains("public func resealingPayload("),
                      "The envelope must re-seal a new payload while keeping every key slot.")

        let app = try readAppViewModelSource()
        // The backup cluster lives in BackupController since the Phase D1 peel; the hub
        // keeps the restore-application half (applyRestoredBackupPayload) pinned below.
        let controller = try readSource(.backupController)
        XCTAssertTrue(controller.contains("private func refreshLocalEncryptedBackupEnvelope()"))
        XCTAssertTrue(controller.contains("envelope.resealingPayload(payload, deviceSecret: deviceSecret)"),
                      "Changes must re-seal the local envelope with the current config + library.")

        // Re-seal runs even when automatic upload is off, so the local envelope stays current.
        let scheduleBlock = try sourceBlock(
            in: controller,
            startingAt: "func scheduleAutomaticBackupAfterConfigurationChange() {",
            endingBefore: "private func runScheduledAutomaticBackup("
        )
        let resealIdx = try XCTUnwrap(scheduleBlock.range(of: "refreshLocalEncryptedBackupEnvelope()")?.lowerBound)
        // Re-seal must run BEFORE the cached-state gate, not after: a stale .off encryptedBackupState
        // right after a restore would otherwise short-circuit the re-seal and drop post-restore edits.
        let configuredGateIdx = try XCTUnwrap(scheduleBlock.range(of: "encryptedBackupState.isConfigured")?.lowerBound)
        XCTAssertLessThan(resealIdx, configuredGateIdx,
                          "Re-seal must be decoupled from the cached backup state (run before the isConfigured gate).")

        // Library migration and active-field projection execute in BackupRestorePlanTests.
        // These pins cover only the app-only staging, persistence and notification boundaries.
        let prepare = try sourceBlock(in: controller, startingAt: "func prepareEncryptedBackupRestore(",
                                      endingBefore: "func discardPreparedBackupRestore(")
        let confirm = try sourceBlock(in: controller, startingAt: "func confirmPreparedBackupRestore(",
                                      endingBefore: "func clearEncryptedBackup() async {")
        let apply = try sourceBlock(in: app, startingAt: "func applyReviewedBackup(",
                                    endingBefore: "// MARK: - LavaSecurity+ hub bridge")
        XCTAssertTrue(prepare.contains("let replacementToken = hub.beginConfigurationReplacement()"))
        XCTAssertTrue(prepare.contains("hub.isConfigurationReplacementCurrent(replacementToken) else"))
        XCTAssertTrue(prepare.contains("try Task.checkCancellation()"))
        XCTAssertTrue(prepare.contains("try hub.prepareBackupRestorePlan(payload)"))
        XCTAssertFalse(prepare.contains("saveDeviceSecret("))
        XCTAssertFalse(prepare.contains("saveLocalEncryptedBackupEnvelope("))
        XCTAssertFalse(prepare.contains("applyReviewedBackup("))
        XCTAssertTrue(prepare.contains("guard let rekeyed = envelope.rekeyingDeviceSlotWithNormalizedRecoveryPhrase("))
        XCTAssertTrue(prepare.contains("guard let rekeyed = try? envelope.rekeyingDeviceSlot("))
        XCTAssertTrue(confirm.contains("pending.review.id == id"))
        let check = try XCTUnwrap(confirm.range(of: "try hub.validateBackupRestorePlan(")?.lowerBound)
        let consume = try XCTUnwrap(confirm.range(of: "pendingRestore = nil")?.lowerBound)
        let key = try XCTUnwrap(confirm.range(of: "try backupKeychainStore.saveDeviceSecret(")?.lowerBound)
        let save = try XCTUnwrap(confirm.range(of: "try backupEnvelopeStore.saveEnvelope(acceptedEnvelope)")?.lowerBound)
        let applyIndex = try XCTUnwrap(confirm.range(of: "try await hub.applyReviewedBackup(")?.lowerBound)
        XCTAssertLessThan(check, consume)
        XCTAssertLessThan(consume, key)
        XCTAssertLessThan(applyIndex, key)
        XCTAssertLessThan(key, save)
        XCTAssertFalse(confirm.contains("try? backupKeychainStore.saveDeviceSecret"))
        XCTAssertTrue(confirm.contains("loadEncryptedBackupState()"))
        XCTAssertTrue(apply.contains("try validateBackupRestorePlan(plan, resolverChangeConfirmed: resolverChangeConfirmed)"))
        XCTAssertTrue(apply.contains("configuration = plan.configuration"))
        XCTAssertTrue(apply.contains("library = plan.library"))
        XCTAssertTrue(apply.contains("filterDrafts.resetSessions()"))
        XCTAssertTrue(apply.contains("prioritizesConfigurationDurability: true"))
        XCTAssertTrue(apply.contains("expectedConfigurationGeneration: plan.previousConfiguration.configurationGeneration"))
        XCTAssertTrue(app.contains("rejectsAdvancedBeyond: expectedConfigurationGeneration"))
    }

    func testRestoreToDefaultClearsEditDraftAndClaimsTheReplacementGate() throws {
        // Restore-to-default is a wholesale config+library replacement, so it must (a) claim the
        // replacement gate like the other replacers and (b) drop any in-flight My filter edit
        // draft — otherwise a draft preserved by the edge-swipe path resumes on the next My
        // filter open and Save applies a pre-restore edit over the freshly seeded Balanced
        // filter with no second restore confirmation (#118 follow-up).
        let app = try readAppViewModelSource()
        let restore = try sourceBlock(
            in: app,
            startingAt: "func restoreFiltersToDefault() {",
            endingBefore: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {"
        )
        XCTAssertTrue(restore.contains("configurationReplacementGate.begin()"),
                      "Restore must claim the replacement gate.")
        // Per-filter: restore reseeds the whole library, so it wipes ALL drafts (not a single slot).
        XCTAssertTrue(restore.contains("filterDrafts.resetSessions()"),
                      "Restore must wipe every per-filter draft before reseeding.")
        // The draft wipe must precede the library swap (drafts are sourced from the old library).
        let clearIdx = try XCTUnwrap(restore.range(of: "filterDrafts.resetSessions()")?.lowerBound)
        let swapIdx = try XCTUnwrap(restore.range(of: "library = .seededDefaults(active: .balanced)")?.lowerBound)
        XCTAssertLessThan(clearIdx, swapIdx, "Drafts must be wiped before the library is replaced.")
    }

    // MARK: - Phase 1: surfaces (FiltersView)

    func testFiltersViewExposesInEffectRowAllFiltersPageAndSwitch() throws {
        let source = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(source.contains("model.beginViewingFilterDetail(id: id)"))
        XCTAssertTrue(source.contains("model.beginCreatingFilter(duplicatingFilterID: templateID)"))
        XCTAssertTrue(source.contains("await model.switchToFilter(id: id)"))
        XCTAssertTrue(source.contains("guard library.editSession == reviewedSession, library.commitStagedDeletions()"))
    }

    func testNonActiveFilterViewIsDecoupledFromTheActiveFilter() throws {
        let app = try readAppViewModelSource()

        // The app forwards to the sole draft owner. Per-filter keying, clean/dirty
        // teardown, and rollback are executable in FilterDraftSessionStateTests.
        XCTAssertTrue(app.contains("private(set) lazy var filterDrafts = FilterDraftController(context: self)"))
        XCTAssertFalse(app.contains("var filterEditDrafts:"))
        XCTAssertTrue(app.contains("var filterEditTargetID: String?"))
        let proxy = try sourceBlock(
            in: app,
            startingAt: "var filterEditDraft: FilterEditDraft? {",
            endingBefore: "var activeFilterDraft: FilterEditDraft? {"
        )
        XCTAssertTrue(proxy.contains("get { filterDrafts.draft(activeFilterID: activeFilterID) }"))
        XCTAssertTrue(proxy.contains("set { filterDrafts.setCurrentDraft(newValue, activeFilterID: activeFilterID) }"))
        XCTAssertTrue(app.contains("get { filterDrafts.sessions.drafts[activeFilterID] }"),
                      "activeFilterDraft keys by the active id regardless of the detail target.")

        // FilterEditScope is gone (it was vestigial — only .blockedDomains was ever used); "is
        // editing" is now simply "the current filter has a draft".
        XCTAssertFalse(app.contains("FilterEditScope"), "Per-filter: the vestigial scope enum must be removed.")
        XCTAssertFalse(app.contains("filterEditScope"), "Per-filter: the filterEditScope property/clears must be gone.")
        XCTAssertTrue(app.contains("var isFilterEditing: Bool {"))

        // The detail baseline still substitutes the target's four fields (unchanged), and editing
        // seeds the draft from it.
        let baseline = try sourceBlock(
            in: app,
            startingAt: "var filterDetailBaseline: AppConfiguration {",
            endingBefore: "var detailFilter: Filter {"
        )
        XCTAssertTrue(baseline.contains("guard let id = filterEditTargetID, let target = filter(id: id) else"))
        for field in ["enabledBlocklistIDs", "customBlocklists", "blockedDomains", "allowedDomains"] {
            XCTAssertTrue(baseline.contains("baseline.\(field) = target.\(field)"))
        }
        XCTAssertTrue(app.contains("filterDrafts.beginEditing(baseline: filterDetailBaseline, activeFilterID: activeFilterID)"))

        // beginViewingFilterDetail just points the page at a filter — no stale-draft drop, because
        // each filter's draft lives under its own key (opening B never touches A's draft).
        let begin = try sourceBlock(
            in: app,
            startingAt: "func beginViewingFilterDetail(id: String?) {",
            endingBefore: "func endViewingFilterDetail() {"
        )
        XCTAssertTrue(begin.contains("filterDrafts.beginViewing(id: id, activeFilterID: activeFilterID)"))
        XCTAssertFalse(begin.contains("filterEditDraft = nil"), "Per-filter: opening a filter must not drop another's draft.")

        // endViewingFilterDetail unifies active/non-active: drop a CLEAN draft, keep a DIRTY one in
        // its per-filter slot (resume on re-open), then stop targeting. No active/non-active branch.
        let end = try sourceBlock(
            in: app,
            startingAt: "func endViewingFilterDetail() {",
            endingBefore: "var isFilterEditing: Bool {"
        )
        XCTAssertTrue(end.contains("filterDrafts.endViewing(activeFilterID: activeFilterID, hasChanges: filterDraftHasChanges)"))

        // The single-slot guards are GONE: no discard-prediction, no Apply/View discard dialogs, no
        // root-nav reset, no cancelFilterEditingOnPageDisappear.
        XCTAssertFalse(app.contains("filterActionDiscardsUnsavedDraft"))
        XCTAssertFalse(app.contains("resetNonActiveFilterDetailOnRootNavigation"))
        XCTAssertFalse(app.contains("cancelFilterEditingOnPageDisappear"))
        let rootView = try readSource(.rootView)
        XCTAssertFalse(rootView.contains("resetNonActiveFilterDetailOnRootNavigation"))

        // Domain History edits the ACTIVE filter's keyed draft (activeFilterDraft) and refuses only
        // when the ACTIVE filter has an unsaved draft (a non-active filter's draft is irrelevant).
        let stage = try sourceBlock(
            in: app,
            startingAt: "func stageDomainHistoryDomainAction(",
            endingBefore: "func removeAllowedDomainFromDraft("
        )
        XCTAssertTrue(stage.contains("if hasUnsavedActiveFilterDraft {"))
        XCTAssertTrue(stage.contains("activeFilterDraft = FilterEditDraft(configuration: result.configuration)"))

        // deleteFilter just drops the deleted filter's keyed draft.
        let delete = try sourceBlock(
            in: app,
            startingAt: "func deleteFilter(id: String) -> Bool {",
            endingBefore: "func restoreFiltersToDefault()"
        )
        XCTAssertTrue(delete.contains("filterDrafts.setDraft(nil, for: id)"))

        let bridge = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(bridge.contains("model.endViewingFilterDetail()"))
        XCTAssertTrue(bridge.contains("model.beginViewingFilterDetail(id: id)"))

    }

    func testNonActiveFilterEditAppliesLibraryOnlyWithNoRecompile() throws {
        let app = try readAppViewModelSource()

        // The non-active save is a dedicated method (NOT the active prepareAndApplyFilterDraft
        // path): it returns a message on failure so the caller shows it inline rather than the
        // full-screen preparation cover.
        let nonActive = try sourceBlock(
            in: app,
            startingAt: "func saveNonActiveFilterDraft() -> String? {",
            endingBefore: "// MARK: - Multi-filter library"
        )
        // Library-only: mutateFilter + persistLibraryOnlyChange, invalidates the compiled token.
        XCTAssertTrue(nonActive.contains("library.mutateFilter(id: targetID)"))
        XCTAssertTrue(nonActive.contains("filter.lastCompiledToken = nil"))
        let activeRecheck = try XCTUnwrap(
            nonActive.range(of: "guard targetID != library.activeFilterID else {")?.lowerBound,
            "A target that became active must leave the library-only save path before mutation.")
        let mutation = try XCTUnwrap(nonActive.range(of: "library.mutateFilter(id: targetID)")?.lowerBound)
        XCTAssertLessThan(activeRecheck, mutation)
        XCTAssertTrue(
            nonActive.contains("filterEditTargetID = nil"),
            "When the target became active, route the detail surface back to active context while preserving its keyed draft.")

        let persist = try XCTUnwrap(
            nonActive.range(
                of: "persistLibraryOnlyChange(\n            rollingBackTo: previousLibrary,\n            refusesIfOnDiskActiveFilterIs: targetID")?.lowerBound,
            "The write must also refuse when a cross-process switch made the target active on disk.")
        let keyedDraftClear = try XCTUnwrap(
            nonActive.range(of: "filterDrafts.setDraft(nil, for: targetID)", range: persist..<nonActive.endIndex)?.lowerBound)
        let warm = try XCTUnwrap(nonActive.range(of: "Task { await warmFilterArtifact(forFilterID: targetID) }")?.lowerBound)
        XCTAssertFalse(
            nonActive.contains("configurationReplacementGate.begin()"),
            "A library-only save must not steal replacement ownership from a switch that already committed its pair but still owes the cache/tunnel tail.")
        XCTAssertLessThan(persist, keyedDraftClear)
        XCTAssertLessThan(keyedDraftClear, warm)
        // Validation runs but reports inline (returns the message) — no failure cover.
        XCTAssertTrue(nonActive.contains("return validationMessage"))
        // The inline save never compiles, writes shared state, reloads the tunnel, or presents the
        // cover; the compile happens off the hot path via a fire-and-forget warm (asserted below).
        XCTAssertTrue(nonActive.contains("Task { await warmFilterArtifact(forFilterID: targetID) }"),
                      "A non-active edit re-warms the filter off the hot path for instant switching.")
        XCTAssertFalse(nonActive.contains("prepareFilterSnapshot"),
                       "A non-active edit must not compile a snapshot INLINE (warm is off-path).")
        XCTAssertFalse(nonActive.contains("persistSharedState"),
                       "A non-active edit must not write shared state / reload the tunnel.")
        XCTAssertFalse(nonActive.contains("notifyTunnelSnapshotUpdated"),
                       "A non-active edit must not reload the tunnel.")
        XCTAssertFalse(nonActive.contains("isFilterPreparationScreenPresented = true"),
                       "A non-active edit must not present the full-screen preparation cover.")
        XCTAssertFalse(nonActive.contains("catalogStatusIsError"),
                       "A non-active library-only failure must not flip the global catalog/protection error flag.")

        let bridge = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(bridge.contains("if model.isViewingNonActiveFilter {"))
        XCTAssertTrue(bridge.contains("saveNonActiveFilterDraft()"))
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(app.contains("prepareFilterSnapshot"))
        XCTAssertTrue(app.contains("persistSharedState"))
        XCTAssertTrue(app.contains("notifyTunnelSnapshotUpdated"))
        XCTAssertTrue(app.contains("isFilterPreparationScreenPresented"))
        XCTAssertTrue(app.contains("catalogStatusIsError"))
    }

    func testPreparationCoverIsOriginScopedAndReSealClearsUploadMarker() throws {
        let app = try readAppViewModelSource()
        // Origin-scoped preparation cover: the model tracks which surface owns the shared cover,
        // set at the apply/switch entry points (not at staging, so it can't go stale).
        XCTAssertTrue(app.contains("var filterPreparationOrigin: FilterReviewOrigin"))
        XCTAssertTrue(app.contains("func prepareAndApplyFilterDraft(origin: FilterReviewOrigin"))
        XCTAssertTrue(app.contains("filterPreparationOrigin = origin"))
        let switchBlock = try sourceBlock(
            in: app,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "func duplicateName(of name: String)"
        )
        XCTAssertTrue(switchBlock.contains("filterPreparationOrigin = .filters"),
                      "A switch is a Filters-tab action and must claim the Filters origin.")

        // Re-seal clears the upload marker so currentState() doesn't report a stale .synced after a
        // local change (Settings would otherwise claim the latest backup is already uploaded).
        // (Backup cluster: BackupController since the Phase D1 peel.)
        let controller = try readSource(.backupController)
        let resealBlock = try sourceBlock(
            in: controller,
            startingAt: "private func refreshLocalEncryptedBackupEnvelope()",
            endingBefore: "private func loadLocalEncryptedBackupEnvelope()"
        )
        XCTAssertTrue(resealBlock.contains("currentPayload.hasSameBackupContent(as: payload)"),
                      "Re-seal must be skipped when backup CONTENT is unchanged (ignoring the protection " +
                      "hint + stripped cache tokens), so a non-user persist / protection toggle doesn't " +
                      "churn the marker / schedule a redundant upload.")
        XCTAssertTrue(resealBlock.contains("backupEnvelopeStore.clearUploadMarker()"),
                      "A local re-seal must clear the stale upload marker.")
        XCTAssertTrue(resealBlock.contains("loadEncryptedBackupState()"),
                      "And refresh the cached state so Settings reflects 'not yet uploaded'.")
        // PST-5 (Codex #218): the refresh path must NOT downgrade a future-schema local envelope. When
        // decrypt throws unsupportedSchemaVersion it must skip the reseal (return), not swallow it and
        // overwrite the newer envelope with a schema-1 payload.
        XCTAssertTrue(resealBlock.contains("catch BackupConfigurationPayloadError.unsupportedSchemaVersion"),
                      "Re-seal must distinguish an unsupported (newer) schema and skip, not downgrade it.")
        // PST-5 (Codex #218 round 2): a RESTORE that hits a newer-schema payload (correct unlock secret
        // but undecodable schema) must surface a DISTINCT actionable error, not be mislabeled as a wrong
        // device key / phrase / passkey. A dedicated case + the restore decrypt paths mapping to it.
        XCTAssertTrue(controller.contains("case unsupportedBackupSchema"),
                      "A newer-schema restore needs its own actionable 'update the app' error.")
        XCTAssertTrue(controller.contains("throw EncryptedBackupError.unsupportedBackupSchema"),
                      "The restore decrypt paths must map unsupportedSchemaVersion to that distinct error, " +
                      "before the generic invalid-unlock catch.")

        // An in-flight upload must version-check the local envelope before recording .synced, so a
        // re-seal during the upload can't leave a stale "uploaded" marker for the older envelope.
        // The version check itself (was AppViewModel.recordEncryptedBackupUploadIfStillCurrent) is
        // BackupEnvelopeStore.recordUploadIfCurrent since the Phase D1 peel, executable in
        // BackupEnvelopeStoreTests.testRecordUploadIfCurrentRefusesWhenEnvelopeWasResealedMidUpload;
        // here, pin only that the upload path routes through it.
        XCTAssertTrue(controller.contains("backupEnvelopeStore.recordUploadIfCurrent(envelope, at: uploadedAt)"),
                      "Upload must only record the marker if the uploaded envelope is still current.")

        // Domain History applies through the shared review flow with its own origin, and its cover
        // gates on that origin so the always-mounted Filters cover can't steal the presentation.
        let review = try readSource(.filterReviewFlowView)
        let bridge = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(bridge.contains("prepareAndApplyFilterDraft(origin: .filters)"))
        XCTAssertTrue(bridge.contains("prepareAndApplyFilterDraft(origin: standaloneToken == nil ? .filters : .domainHistory)"))
        XCTAssertTrue(bridge.contains("standaloneDomainReviews"))

        // The shared failure screen tailors its affordances: "Try Again" only when the failure is
        // retryable (a deleted/frozen switch target is a dead end), and "Back to Edit"/"Back to
        // Review" only when there's an editor/review to return to (a switch has neither).
        XCTAssertTrue(review.contains("if drafts.preparationFailureIsRetryable {"),
                      "Try Again must be hidden for a non-retryable (deleted/frozen-target) failure.")
        XCTAssertTrue(review.contains("if viewModel.filterPreparationFailureOffersEditReturn {"),
                      "Back to Edit/Review must be hidden when there's no editor (a filter switch).")
        XCTAssertTrue(app.contains("var filterPreparationFailureOffersEditReturn: Bool {"))
        XCTAssertTrue(app.contains("pendingSwitchFilterID == nil"),
                      "A switch failure (pendingSwitchFilterID set) must not offer the edit return.")
    }

    func testFrozenFiltersAreReadOnlyAndEditModeIsAuthGated() throws {
        let source = try readSource(.reactNativeAppFilters)
        XCTAssertTrue(source.contains("!library.isFilterFrozen(id)"))
        XCTAssertTrue(source.contains("if model.isFilterFrozen(id) { model.cancelFilterEditing()"))
        XCTAssertTrue(source.contains("try await authorize(.filterEditing, \"Manage filters\")"))
        XCTAssertTrue(source.contains("try await authorize(.filterEditing, \"Switch filter\", fresh: true)"))
    }

    // MARK: - Helpers
}
