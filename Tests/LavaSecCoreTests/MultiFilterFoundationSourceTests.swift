import XCTest
@testable import LavaSecCore

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
        XCTAssertEqual(FeatureLimits.paid.maxFilters, 10, "Plus hosts up to ten filters.")
        XCTAssertFalse(FeatureLimits.paid.hasUnlimitedFilters, "Plus is capped at 10, not unlimited.")
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
        let source = try Self.source(named: "AppGroup.swift", in: "Shared")
        XCTAssertTrue(source.contains(#"filterLibraryFilename = "filter-library.json""#))
    }

    // MARK: - Persistence boundary keeps the library in lockstep

    func testConfigOnlyPersistSyncsAndWritesTheLibrary() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func syncActiveFilterFromConfiguration()"
        )
        XCTAssertTrue(block.contains("syncActiveFilterFromConfiguration()"),
                      "Config-only writes must mirror the active filter into the library.")
        XCTAssertTrue(block.contains("try persistFilterLibrary()"),
                      "Config-only writes must persist filter-library.json alongside the config.")
    }

    func testSharedStatePersistSyncsRecordsTokenAndWritesLibrary() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "let didRewriteArtifacts = rewritesRuleArtifacts",
            endingBefore: "private func persistConfigurationOnly("
        )
        XCTAssertTrue(block.contains("syncActiveFilterFromConfiguration()"))
        XCTAssertTrue(block.contains("try persistFilterLibrary()"))
        // Only a real artifact rewrite records the compiled token (so GC keeps the
        // active filter's dir warm); a reuse/no-op publish must not mint a token.
        XCTAssertTrue(block.contains("if didRewriteArtifacts {"))
        XCTAssertTrue(block.contains("FilterArtifactStore.versionedToken(for: snapshotToPersist)"))
        XCTAssertTrue(block.contains("$0.lastCompiledToken = token"))
    }

    func testSyncActiveFilterClearsStaleTokenOnlyOnRealChange() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "private func syncActiveFilterFromConfiguration() {",
            endingBefore: "private func persistFilterLibrary()"
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
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let loadBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadPersistedConfiguration() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        XCTAssertTrue(loadBlock.contains("loadOrMigrateFilterLibrary()"),
                      "The launch load must always load/migrate the library.")

        let migrateBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func persistDiagnostics()"
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
    }

    // MARK: - GC widen

    func testArtifactPublishRetainsEveryFilterCompiledToken() throws {
        let appSource = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let publishBlock = try Self.sourceBlock(
            in: appSource,
            startingAt: "private func persistPreparedSnapshotArtifacts(",
            endingBefore: "private func retainedFilterArtifactTokens()"
        )
        XCTAssertTrue(publishBlock.contains("additionalRetainedTokens: retainedFilterArtifactTokens()"),
                      "Publish must pass the hosted filters' tokens so GC keeps them warm.")

        let retainBlock = try Self.sourceBlock(
            in: appSource,
            startingAt: "private func retainedFilterArtifactTokens() -> [String] {",
            endingBefore: "private func persistSharedState("
        )
        XCTAssertTrue(retainBlock.contains("filter.lastCompiledToken"),
                      "Retention is built from each hosted filter's compiled token.")
        XCTAssertTrue(retainBlock.contains("library.filter(id: activeID)?.lastCompiledToken"),
                      "The active filter's token leads the warm set (most likely switch-back).")

        // The core GC must actually fold the extra tokens into its retained set.
        let coreSource = try Self.source(named: "FilterSnapshotPreparationService.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(coreSource.contains("additionalRetainedTokens: [String] = []"),
                      "persistArtifacts must accept the extra retained tokens (default empty ⇒ today's behaviour).")
        XCTAssertTrue(coreSource.contains("+ additionalRetainedTokens"),
                      "The extra tokens must be unioned into collectVersionedGarbage's retained set.")
    }

    // MARK: - Phase 1: switch / create / delete (view-model)

    func testSwitchCommitsOnlyAfterPrepareAndKeepsPreviousOnFailure() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "func switchToFilter(id: String) async {",
            endingBefore: "private func duplicateName(of name: String)"
        )
        // Refuses no-op / unknown / frozen targets.
        XCTAssertTrue(block.contains("guard id != library.activeFilterID,"))
        XCTAssertTrue(block.contains("!isFilterFrozen(id)"))
        // Prepares first; commits configuration + active id only after a successful prepare.
        let prepareIdx = try XCTUnwrap(block.range(of: "try await prepareFilterSnapshot(for: nextConfiguration)")?.lowerBound)
        let commitIdx = try XCTUnwrap(block.range(of: "library.setActiveFilter(id: id)")?.lowerBound)
        XCTAssertLessThan(prepareIdx, commitIdx, "The switch must commit only after prepare succeeds.")
        XCTAssertTrue(block.contains("configuration = nextConfiguration"))
        XCTAssertTrue(block.contains("try await persistSharedState(preparedSnapshot: prepared.snapshot)"))
        // Derived rule caches (applyCatalogSyncResult) are applied only AFTER the throwing persist,
        // so a failed switch never leaves them describing the target (the rollback can't restore them).
        let persistIdx = try XCTUnwrap(block.range(of: "try await persistSharedState(preparedSnapshot: prepared.snapshot)")?.lowerBound)
        let applyCatalogIdx = try XCTUnwrap(block.range(of: "applyCatalogSyncResult(prepared.catalogResult)")?.lowerBound)
        XCTAssertLessThan(persistIdx, applyCatalogIdx, "Derived catalog/rule state must be applied only after the switch persists.")
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
        // Overlapping switches AND switch-vs-restore/import are serialized by the shared
        // configuration-replacement gate: the attempt claims a token and bails before committing
        // if a newer replacement superseded it.
        XCTAssertTrue(block.contains("let switchToken = configurationReplacementGate.begin(ownsPreparationCover: true)"))
        let supersedeCommitIdx = try XCTUnwrap(successPart.range(of: "guard configurationReplacementGate.isCurrent(switchToken) else {")?.lowerBound)
        let successCommitIdx = try XCTUnwrap(successPart.range(of: "library.setActiveFilter(id: id)")?.lowerBound)
        XCTAssertLessThan(supersedeCommitIdx, successCommitIdx, "A superseded switch must bail before committing.")
        // The target may have been deleted OR frozen (Plus lapsed) during the async prepare —
        // re-validate both before commit, and surface it as a NON-retryable failure (retrying a
        // gone/frozen target just re-fails) instead of silently dropping the cover.
        XCTAssertTrue(block.contains("guard library.filter(id: id) != nil, !isFilterFrozen(id) else {"))
        let unavailableGuardIdx = try XCTUnwrap(successPart.range(of: "guard library.filter(id: id) != nil, !isFilterFrozen(id) else {")?.upperBound)
        let unavailableBody = String(successPart[unavailableGuardIdx...])
        XCTAssertTrue(unavailableBody.contains("filterPreparationFailureIsRetryable = false"),
                      "A deleted/frozen target must surface a non-retryable failure.")
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
        XCTAssertTrue(catchBlock.contains("configuration = previousConfiguration"),
                      "Failure must roll the config back to the previously-loaded filter.")
        XCTAssertTrue(catchBlock.contains("library.setActiveFilter(id: previousActiveID)"),
                      "Failure must roll the active id back to the previously-loaded filter.")
        XCTAssertTrue(catchBlock.contains("try? persistConfigurationOnly()"),
                      "The rollback must be persisted (persistSharedState may have written the target to disk before the publish threw).")
        XCTAssertFalse(catchBlock.contains("configuration = nextConfiguration"), "Failure must not commit the target config.")
        XCTAssertFalse(catchBlock.contains("setActiveFilter(id: id)"), "Failure must not commit the target active id.")
    }

    /// All FOUR wholesale config+library replacers (switch, restore, import, draft-apply) must
    /// claim the shared gate before their first await and re-check it before committing AND before
    /// the post-persist (artifact-actor await) side-effect tail — otherwise a superseded replacer
    /// silently reverts a concurrent one or desyncs the rule caches.
    func testEveryWholesaleReplacerClaimsAndRechecksTheGate() throws {
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // Import: claims importToken, re-checks before commit AND after the persist (applyCatalogSyncResult
        // is deferred past the persist so a superseded import can't desync caches).
        let importBlock = try Self.sourceBlock(
            in: app,
            startingAt: "func applyImportedShareableConfiguration(",
            endingBefore: "func retryFilterPreparation()"
        )
        XCTAssertTrue(importBlock.contains("let importToken = configurationReplacementGate.begin()"))
        let importPersistIdx = try XCTUnwrap(importBlock.range(of: "try await persistSharedState(preparedSnapshot: prepared.snapshot)")?.lowerBound)
        let importApplyIdx = try XCTUnwrap(importBlock.range(of: "applyCatalogSyncResult(prepared.catalogResult)")?.lowerBound)
        XCTAssertLessThan(importPersistIdx, importApplyIdx, "Import must defer derived-cache apply past the persist.")
        XCTAssertTrue(String(importBlock[importPersistIdx..<importApplyIdx]).contains("guard configurationReplacementGate.isCurrent(importToken)"),
                      "Import must re-check the gate after the persist await, before its tail.")
        let importCommitIdx = try XCTUnwrap(importBlock.range(of: "configuration = nextConfiguration")?.lowerBound)
        let importPrecheckIdx = try XCTUnwrap(importBlock.range(of: "guard configurationReplacementGate.isCurrent(importToken)")?.lowerBound)
        XCTAssertLessThan(importPrecheckIdx, importCommitIdx, "Import must re-check the gate before committing.")

        // Draft apply: a fourth wholesale replacer — claims draftToken, re-checks before commit AND
        // after the persist, and resets the retryable flag so a prior dead-end switch can't leak.
        let draftBlock = try Self.sourceBlock(
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
        XCTAssertLessThan(draftPersistIdx, draftApplyIdx, "Draft apply must defer derived-cache apply past the persist.")
        XCTAssertTrue(String(draftBlock[draftPersistIdx..<draftApplyIdx]).contains("guard configurationReplacementGate.isCurrent(draftToken) else {"),
                      "Draft apply must re-check the gate after the persist await, before its tail.")
        // The catch must ALSO re-check (like switchToFilter's catch): a superseded apply that throws
        // must not stomp the winner's preparation cover with a spurious .failed + haptic.
        let draftCatch = String(draftBlock[(try XCTUnwrap(draftBlock.range(of: "} catch {")?.upperBound))...])
        let draftCatchGuardIdx = try XCTUnwrap(draftCatch.range(of: "guard configurationReplacementGate.isCurrent(draftToken) else {")?.lowerBound)
        let draftCatchFailedIdx = try XCTUnwrap(draftCatch.range(of: "filterPreparationState = .failed(")?.lowerBound)
        XCTAssertLessThan(draftCatchGuardIdx, draftCatchFailedIdx,
                          "The draft-apply catch must bail when superseded before touching the shared cover.")

        // Cover-driving replacers (switch + draft apply) claim the gate as cover owners so a
        // superseded one knows to dismiss its stranded spinner when a non-cover-driver (restore/
        // import) supersedes it; restore/import claim as non-owners (plain begin()).
        XCTAssertTrue(app.contains("configurationReplacementGate.begin(ownsPreparationCover: true)"),
                      "Switch + draft apply must claim the gate as preparation-cover owners.")
        XCTAssertEqual(app.components(separatedBy: "begin(ownsPreparationCover: true)").count - 1, 2,
                       "Exactly the two cover-driving replacers (switch + draft apply) own the cover.")
        XCTAssertTrue(app.contains("private func dismissPreparationCoverIfStrandedBySupersession()"),
                      "A superseded cover-driver dismisses its stranded cover via a shared helper.")
        XCTAssertTrue(app.contains("guard !configurationReplacementGate.currentOwnerOwnsPreparationCover else { return }"),
                      "The dismiss helper must no-op when the new owner is itself a cover-driver.")
        // Every supersession bail in the two cover-driving replacers routes through the helper
        // (switch: commit + post-persist + rollback; draft apply: commit + post-persist + catch).
        XCTAssertEqual(app.components(separatedBy: "dismissPreparationCoverIfStrandedBySupersession()").count - 1, 7,
                       "Six supersession bails call the dismiss helper, plus its one definition.")

        // The retryable flag must ONLY be reset to true at the two fresh-attempt entry points
        // (switch + draft apply) — not scattered — and set false only on the dead-end edge. Total
        // `= true` sites = 1 property-declaration default + those 2 resets.
        XCTAssertEqual(app.components(separatedBy: "filterPreparationFailureIsRetryable = true").count - 1, 3,
                       "Retryability resets only at the two fresh-attempt entry points (+ the declaration default).")
        XCTAssertEqual(app.components(separatedBy: "filterPreparationFailureIsRetryable = false").count - 1, 1,
                       "Retryability is cleared only on the single deleted/frozen dead-end edge.")
    }

    func testWarmArtifactRetentionIsBounded() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "private func retainedFilterArtifactTokens() -> [String] {",
            endingBefore: "private func persistSharedState("
        )
        // Disk stays bounded as the library grows: the warm set is capped, not O(N filters).
        XCTAssertTrue(source.contains("maxWarmFilterArtifacts = 8"))
        XCTAssertTrue(block.contains("prefix(Self.maxWarmFilterArtifacts)"))
    }

    func testCreateFilterIsPlusGatedAndLibraryOnly() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.sourceBlock(
            in: source,
            startingAt: "func createFilter(name: String, duplicatingFilterID:",
            endingBefore: "func renameFilter(id: String"
        )
        XCTAssertTrue(block.contains("guard canCreateFilter else { return nil }"),
                      "Creating a filter must be gated on the tier filter cap.")
        XCTAssertTrue(block.contains("library.append(newFilter)"))
        XCTAssertTrue(block.contains("persistFilterLibrary()"))
        XCTAssertFalse(block.contains("notifyTunnelSnapshotUpdated"),
                       "A new (non-active) filter must not recompile or republish.")
    }

    func testDeleteFilterDelegatesToInvariantSafeRemoval() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let deleteBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func deleteFilter(id: String) -> Bool {",
            endingBefore: "func switchToFilter(id: String) async {"
        )
        // library.remove refuses the active filter and the last remaining filter; the
        // model also enforces the read-only freeze (below the UI affordances).
        XCTAssertTrue(deleteBlock.contains("guard !isFilterFrozen(id)"),
                      "Delete must refuse a frozen (read-only) filter at the model layer.")
        XCTAssertTrue(deleteBlock.contains("library.remove(id: id)"),
                      "Delete must use the invariant-safe removal (refuses active / last).")

        // rename enforces the same model-level freeze.
        let renameBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func renameFilter(id: String, to name: String) {",
            endingBefore: "func deleteFilter(id: String) -> Bool {"
        )
        XCTAssertTrue(renameBlock.contains("!isFilterFrozen(id)"),
                      "Rename must refuse a frozen (read-only) filter at the model layer.")
    }

    func testFrozenFilterRuleMatchesDowngradeSemantics() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // Freeze is count-aware: nothing freezes while the library fits the tier cap (Free's three
        // seeded filters are all switchable); only a lapsed-Plus library OVER the cap freezes its
        // excess non-active filters. The active filter is never frozen.
        XCTAssertTrue(source.contains("guard library.filters.count > cap, id != library.activeFilterID else { return false }"),
                      "Freeze only applies when the library exceeds the tier cap; the active filter is never frozen.")
    }

    func testMigrationWriteIsSkippedForHeadlessRefreshAndRetryRoutesToSwitch() throws {
        let source = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // The headless background-refresh model must not persist the migration (read-only),
        // or it could overwrite a foreground-created library (read→write race).
        let migrateBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func persistDiagnostics()"
        )
        XCTAssertTrue(migrateBlock.contains("if !isHeadless {"),
                      "Migration persist must be gated to foreground (non-headless) instances.")
        XCTAssertTrue(source.contains("isHeadless = headless"), "init must capture the headless flag.")

        // The shared failure screen's Try Again retries a failed SWITCH (no draft), not a
        // no-op draft apply.
        let retryBlock = try Self.sourceBlock(
            in: source,
            startingAt: "func retryFilterPreparation() {",
            endingBefore: "var tunnelCacheHitRateText"
        )
        XCTAssertTrue(retryBlock.contains("if let id = pendingSwitchFilterID {"))
        XCTAssertTrue(retryBlock.contains("await switchToFilter(id: id)"))
    }

    func testBackupIncludesLibraryAndOrdersPersistWritesByDurability() throws {
        let core = try Self.source(named: "BackupConfigurationPayload.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(core.contains("public let filterLibrary: FilterLibrary?"),
                      "The backup payload must carry the whole filter library.")
        XCTAssertTrue(core.contains("func restoredFilterLibrary() -> FilterLibrary?"))

        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        XCTAssertTrue(app.contains("filterLibrary: library"),
                      "Turn-on must seal the library into the payload.")
        XCTAssertTrue(app.contains("payload.restoredFilterLibrary()"),
                      "Restore must rebuild every hosted filter.")
        XCTAssertTrue(app.contains("private func persistLibraryOnlyChange(rollingBackTo previousLibrary: FilterLibrary)"),
                      "Library-only changes must schedule a backup, like config changes.")
        // A failed library-only write must roll the published library back to its pre-mutation
        // snapshot, so a change reported as failed isn't left live (or persisted later by config).
        let persistLibBlock = try Self.sourceBlock(
            in: app,
            startingAt: "private func persistLibraryOnlyChange(rollingBackTo previousLibrary: FilterLibrary)",
            endingBefore: "func renameFilter(id: String, to name: String)"
        )
        XCTAssertTrue(persistLibBlock.contains("library = previousLibrary"),
                      "A failed library-only write must roll back the in-memory library.")

        // The two files are each atomic but NOT transactional as a pair, so persistSharedState
        // orders them by which side is unreconstructable on a mid-write kill: normal edits persist
        // the library (source of truth) BEFORE config (derived cache); a RESTORE persists config
        // FIRST (prioritizesConfigurationDurability) because the config carries device-global
        // fields the library can't reconstruct.
        let persistBlock = try Self.sourceBlock(
            in: app,
            startingAt: "let configurationURL = containerURL.appendingPathComponent(LavaSecAppGroup.configurationFilename)",
            endingBefore: "if didRewriteArtifacts {"
        )
        let cfgIdx = try XCTUnwrap(persistBlock.range(of: "configurationData.write(to: configurationURL")?.lowerBound)
        // Normal edits persist the library (source of truth) BEFORE the config it derives.
        let normalLibIdx = try XCTUnwrap(persistBlock.range(of: "try persistFilterLibrary()")?.lowerBound)
        XCTAssertLessThan(normalLibIdx, cfgIdx, "Normal edits must persist the library before the config it derives.")
        // Restore (config-durable) writes the unreconstructable config FIRST, then the library AFTER
        // it — a kill before the config lands can't destroy existing filters (Codex r19); a kill
        // after it leaves a lower-generation library that load rejects (Codex r20). No destructive
        // pre-delete: the generation stamp, not file removal, invalidates a stale library.
        let restoreLibIdx = try XCTUnwrap(persistBlock.range(of: "try persistFilterLibrary()", options: .backwards)?.lowerBound)
        XCTAssertLessThan(cfgIdx, restoreLibIdx, "A config-durable (restore) persist must write the new library AFTER the config.")
        XCTAssertFalse(persistBlock.contains("removeFilterLibraryFile"),
                       "The generation marker replaces the destructive pre-delete on the restore path.")

        // The write-race generation marker: persistFilterLibrary stamps the library with the config
        // generation it is paired with, and load rejects a library whose stamp lost the race.
        XCTAssertTrue(app.contains("library.configurationGeneration = configuration.configurationGeneration"),
                      "persistFilterLibrary must stamp the library with the paired config generation.")
        let loadBlock = try Self.sourceBlock(
            in: app,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func persistDiagnostics()"
        )
        XCTAssertTrue(loadBlock.contains("lostWriteRace(againstConfigurationGeneration: configuration.configurationGeneration)"),
                      "Load must reject a library that lost the two-file write race against the config.")
        // persistConfigurationOnly must bump the generation BEFORE writing the library, so the
        // library it stamps and the config it writes carry the same (new) generation.
        let cfgOnlyBlock = try Self.sourceBlock(
            in: app,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func syncActiveFilterFromConfiguration()"
        )
        let bumpIdx = try XCTUnwrap(cfgOnlyBlock.range(of: "advanceConfigurationGeneration()")?.lowerBound)
        let libWriteIdx = try XCTUnwrap(cfgOnlyBlock.range(of: "try persistFilterLibrary()")?.lowerBound)
        XCTAssertLessThan(bumpIdx, libWriteIdx, "persistConfigurationOnly must bump the generation before stamping/writing the library.")
    }

    func testBackupReSealsOnChangeAndRestoreIsLibraryAuthoritative() throws {
        let core = try Self.source(named: "ZeroKnowledgeBackupEnvelope.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(core.contains("public func resealingPayload("),
                      "The envelope must re-seal a new payload while keeping every key slot.")

        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        XCTAssertTrue(app.contains("private func refreshLocalEncryptedBackupEnvelope()"))
        XCTAssertTrue(app.contains("envelope.resealingPayload(payload, deviceSecret: deviceSecret)"),
                      "Changes must re-seal the local envelope with the current config + library.")

        // Re-seal runs even when automatic upload is off, so the local envelope stays current.
        let scheduleBlock = try Self.sourceBlock(
            in: app,
            startingAt: "private func scheduleAutomaticBackupAfterConfigurationChange() {",
            endingBefore: "private func runScheduledAutomaticBackup()"
        )
        let resealIdx = try XCTUnwrap(scheduleBlock.range(of: "refreshLocalEncryptedBackupEnvelope()")?.lowerBound)
        // Re-seal must run BEFORE the cached-state gate, not after: a stale .off encryptedBackupState
        // right after a restore would otherwise short-circuit the re-seal and drop post-restore edits.
        let configuredGateIdx = try XCTUnwrap(scheduleBlock.range(of: "encryptedBackupState.isConfigured")?.lowerBound)
        XCTAssertLessThan(resealIdx, configuredGateIdx,
                          "Re-seal must be decoupled from the cached backup state (run before the isConfigured gate).")

        // Restore is library-authoritative: the restored library's active filter regenerates config.
        let restoreBlock = try Self.sourceBlock(
            in: app,
            startingAt: "if let restoredLibrary = payload.restoredFilterLibrary()",
            endingBefore: "try await persistSharedState("
        )
        XCTAssertTrue(restoreBlock.contains("mirrorActiveFilterIntoConfiguration()"),
                      "Restore must recover the active id + contents together from the restored library.")
        // EVERY hosted filter's known custom blocklists migrate to catalog sources (not just the
        // active one mirrored into config), then normalize BEFORE the isValid check (mirrors the
        // launch load path): a backup with filters but a stale activeFilterID is repaired, not
        // discarded down to one migrated filter.
        let migrateIdx = try XCTUnwrap(restoreBlock.range(of: ".migratingKnownCustomBlocklistsToCatalogSources()")?.lowerBound)
        let normalizeIdx = try XCTUnwrap(restoreBlock.range(of: ".normalized()")?.lowerBound)
        XCTAssertLessThan(migrateIdx, normalizeIdx,
                          "Restore must migrate every hosted filter, then normalize, before isValid.")
        XCTAssertTrue(restoreBlock.contains("filterEditDrafts.removeAll()"),
                      "Restore must wipe all per-filter drafts so none can overwrite the restored library.")

        // After restore the envelope is on disk, so the cached backup state must be refreshed
        // from the store (it was .off on a fresh device); otherwise post-restore edits are gated
        // off by the stale .off state and never re-seal / re-upload.
        let restoreFnBlock = try Self.sourceBlock(
            in: app,
            startingAt: "func restoreEncryptedBackup(secret: String, mode: BackupRestoreMode) async throws {",
            endingBefore: "func clearEncryptedBackup() async {"
        )
        XCTAssertTrue(restoreFnBlock.contains("loadEncryptedBackupState()"),
                      "Restore must refresh the cached backup state from the now-present envelope.")
        // Restore opts into config-first persistence: a partial write must lose the re-restorable
        // library, never the unreconstructable device-global config.
        XCTAssertTrue(restoreFnBlock.contains("persistSharedState(prioritizesConfigurationDurability: true)"),
                      "Restore must persist config-first so a partial write can't reset device-global config to defaults.")

        // A new-device restore (recovery phrase / passkey) re-keys the envelope's device slot
        // with a fresh device secret so the device can re-seal later (otherwise post-restore
        // edits silently never back up).
        XCTAssertTrue(core.contains("unlockingAssistedRecoveryPhrase"))
        XCTAssertTrue(core.contains("unlockingPasskeyPRFOutput"))
        XCTAssertTrue(app.contains("rekeyedEnvelopeWithNormalizedRecoveryPhrase("))
        XCTAssertTrue(app.contains("unlockingPasskeyPRFOutput: prfOutput"))
        // The rekey is REQUIRED for recovery/passkey restores (guard/throw), not best-effort: a
        // silent rekey failure would fall into the device-key path with no saved secret, so
        // post-restore edits would silently stop backing up (Codex r22).
        XCTAssertTrue(restoreFnBlock.contains("guard let rekeyed = rekeyedEnvelopeWithNormalizedRecoveryPhrase("),
                      "A failed recovery-phrase rekey must fail the restore, not proceed.")
        XCTAssertTrue(restoreFnBlock.contains("guard let rekeyed = try? envelope.rekeyingDeviceSlot("),
                      "A failed passkey rekey must fail the restore, not proceed.")
        XCTAssertFalse(restoreFnBlock.contains("if let rekeyed = rekeyedEnvelopeWithNormalizedRecoveryPhrase("),
                       "The recovery rekey must not be best-effort (if let).")
        // The re-key writes must PROPAGATE (not try?) so a failed persist fails the restore
        // instead of silently leaving a saved secret that can't unwrap the on-disk envelope.
        let rekeyPersist = try Self.sourceBlock(
            in: app,
            startingAt: "if didRekeyDeviceSlot {",
            endingBefore: "configuration = payload.restoredConfiguration()"
        )
        XCTAssertTrue(rekeyPersist.contains("try backupKeychainStore.saveDeviceSecret(freshDeviceSecret)"))
        XCTAssertTrue(rekeyPersist.contains("try saveLocalEncryptedBackupEnvelope(localEnvelope)"))
        XCTAssertFalse(rekeyPersist.contains("try? backupKeychainStore.saveDeviceSecret"))

        // Restore is serialized against switch/import by the shared replacement gate: it claims the
        // token at entry (superseding a suspended switch) and re-checks it after the unlock awaits,
        // BEFORE any disk write or app-state mutation, aborting rather than clobbering a newer owner.
        let beginIdx = try XCTUnwrap(restoreFnBlock.range(of: "let replacementToken = configurationReplacementGate.begin()")?.lowerBound)
        let recheckIdx = try XCTUnwrap(restoreFnBlock.range(of: "guard configurationReplacementGate.isCurrent(replacementToken) else {")?.lowerBound)
        let mutateIdx = try XCTUnwrap(restoreFnBlock.range(of: "configuration = payload.restoredConfiguration()")?.lowerBound)
        XCTAssertLessThan(beginIdx, recheckIdx, "Restore must claim the replacement token at entry.")
        XCTAssertLessThan(recheckIdx, mutateIdx, "Restore must re-check the token before mutating app state.")
        XCTAssertTrue(restoreFnBlock.contains("throw EncryptedBackupError.supersededByConcurrentConfigurationChange"))

        // deviceKey reseal-clobber fix: the local envelope is staged BEFORE the persist (whose
        // re-seal then reflects the restored state), and there is NO post-persist save to clobber it.
        let lastStageIdx = try XCTUnwrap(restoreFnBlock.range(of: "saveLocalEncryptedBackupEnvelope(localEnvelope)", options: .backwards)?.lowerBound)
        let persistIdx = try XCTUnwrap(restoreFnBlock.range(of: "persistSharedState(prioritizesConfigurationDurability: true)")?.lowerBound)
        XCTAssertLessThan(lastStageIdx, persistIdx,
                          "Every local-envelope save must precede the persist so the persist's re-seal isn't clobbered.")
    }

    func testRestoreToDefaultClearsEditDraftAndClaimsTheReplacementGate() throws {
        // Restore-to-default is a wholesale config+library replacement, so it must (a) claim the
        // replacement gate like the other replacers and (b) drop any in-flight My filter edit
        // draft — otherwise a draft preserved by the edge-swipe path resumes on the next My
        // filter open and Save applies a pre-restore edit over the freshly seeded Balanced
        // filter with no second restore confirmation (#118 follow-up).
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let restore = try Self.sourceBlock(
            in: app,
            startingAt: "func restoreFiltersToDefault() {",
            endingBefore: "func switchToFilter(id: String) async {"
        )
        XCTAssertTrue(restore.contains("configurationReplacementGate.begin()"),
                      "Restore must claim the replacement gate.")
        // Per-filter: restore reseeds the whole library, so it wipes ALL drafts (not a single slot).
        XCTAssertTrue(restore.contains("filterEditDrafts.removeAll()"),
                      "Restore must wipe every per-filter draft before reseeding.")
        // The draft wipe must precede the library swap (drafts are sourced from the old library).
        let clearIdx = try XCTUnwrap(restore.range(of: "filterEditDrafts.removeAll()")?.lowerBound)
        let swapIdx = try XCTUnwrap(restore.range(of: "library = .seededDefaults(active: .balanced)")?.lowerBound)
        XCTAssertLessThan(clearIdx, swapIdx, "Drafts must be wiped before the library is replaced.")
    }

    // MARK: - Phase 1: surfaces (FiltersView)

    func testFiltersViewExposesInEffectRowAllFiltersPageAndSwitch() throws {
        let source = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        // The in-effect ("Now filtering") row and the library entry are consolidated
        // under a single conversational "What's filtering?" section.
        XCTAssertTrue(source.contains(#"LavaSectionGroup("What's filtering?")"#))
        XCTAssertTrue(source.contains("struct FilterInEffectRow"))
        XCTAssertTrue(source.contains("struct AllFiltersView"))
        XCTAssertTrue(source.contains("struct FilterLibraryRow"))
        XCTAssertTrue(source.contains("struct CreateFilterSheet"))
        XCTAssertTrue(source.contains("viewModel.switchToFilter(id: filter.id)"))
        // Tapping a non-active filter opens an Apply/View dialog; the row defers to it.
        XCTAssertTrue(source.contains("chooseAction: { filterActionChoice = filter }"))
        // Per-filter drafts: Apply/View act directly with no discard confirmation (neither destroys
        // another filter's draft).
        XCTAssertFalse(source.contains("filterActionDiscardsUnsavedDraft"),
                       "Per-filter: the discard-confirmation predicate must be gone.")
        XCTAssertFalse(source.contains("Discard unsaved changes?"),
                       "Per-filter: the Apply/View discard dialog must be gone.")
        // applyFilter switches — a live protection change gated behind the same fresh-auth surface
        // as save/import (the guard must precede the switch call).
        let applyBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func applyFilter(_ filter: Filter) {",
            endingBefore: "private func viewFilter(_ filter: Filter) {"
        )
        let authIdx = try XCTUnwrap(applyBlock.range(of: "requireFreshAuthentication(")?.lowerBound)
        let switchIdx = try XCTUnwrap(applyBlock.range(of: "switchToFilter(id: filter.id)")?.lowerBound)
        XCTAssertLessThan(authIdx, switchIdx, "Fresh-auth must gate the filter switch.")
        XCTAssertTrue(applyBlock.contains("for: .filterEditing"))
        // viewFilter opens the tapped (non-active) filter's detail without loading it.
        let viewBlock = try Self.sourceBlock(
            in: source,
            startingAt: "private func viewFilter(_ filter: Filter) {",
            endingBefore: "@ViewBuilder private var restoreDefaultsButton"
        )
        XCTAssertTrue(viewBlock.contains("viewModel.beginViewingFilterDetail(id: filter.id)"),
                      "View must point the detail page at the tapped non-active filter.")
        XCTAssertTrue(viewBlock.contains("isShowingDetail = true"))
        XCTAssertTrue(source.contains("viewModel.createFilter(name: name, duplicatingFilterID: duplicateFromID)"))
        // The off/empty alarm appears on both the in-effect row and the current-filter detail.
        XCTAssertTrue(source.contains("Blocks nothing — not protected"))
        XCTAssertTrue(source.contains("viewModel.library.activeFilter.isEmpty"))
        // Create routes through the paywall when the user is at the free filter cap.
        XCTAssertTrue(source.contains("if viewModel.canCreateFilter {"))
        XCTAssertTrue(source.contains("isShowingPaywall = true"))
        // The filter-preparation cover must have exactly ONE owner in this view (AllFiltersView
        // pushes MyListCover, so two covers would race), and — since this tab body stays mounted —
        // it must gate on a Filters origin so a Domain History action can't present it.
        let coverCount = source.components(separatedBy: "FilterPreparationScreen(origin: .filters)").count - 1
        XCTAssertEqual(coverCount, 1, "Exactly one filter-preparation cover owner in FiltersView.")
        XCTAssertTrue(source.contains("viewModel.filterPreparationOrigin == .filters"),
                      "The Filters cover must gate on a Filters origin, not the shared boolean alone.")
    }

    func testNonActiveFilterViewIsDecoupledFromTheActiveFilter() throws {
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // PER-FILTER STORAGE: drafts are a dictionary keyed by filter id, with a computed proxy
        // (current = target ?? active) and an active-keyed accessor. This is what dissolves the
        // single-slot aliasing the #120/#121 guards worked around.
        XCTAssertTrue(app.contains("var filterEditDrafts: [String: FilterEditDraft] = [:]"))
        XCTAssertTrue(app.contains("var filterEditTargetID: String?"))
        let proxy = try Self.sourceBlock(
            in: app,
            startingAt: "var filterEditDraft: FilterEditDraft? {",
            endingBefore: "var activeFilterDraft: FilterEditDraft? {"
        )
        XCTAssertTrue(proxy.contains("get { filterEditDrafts[currentEditKey] }"))
        XCTAssertTrue(proxy.contains("set { filterEditDrafts[currentEditKey] = newValue }"))
        XCTAssertTrue(app.contains("filterEditTargetID ?? activeFilterID"),
                      "currentEditKey resolves to the active filter when no non-active target is set.")
        XCTAssertTrue(app.contains("get { filterEditDrafts[activeFilterID] }"),
                      "activeFilterDraft keys by the active id regardless of the detail target.")

        // FilterEditScope is gone (it was vestigial — only .blockedDomains was ever used); "is
        // editing" is now simply "the current filter has a draft".
        XCTAssertFalse(app.contains("FilterEditScope"), "Per-filter: the vestigial scope enum must be removed.")
        XCTAssertFalse(app.contains("filterEditScope"), "Per-filter: the filterEditScope property/clears must be gone.")
        XCTAssertTrue(app.contains("var isFilterEditing: Bool {"))

        // The detail baseline still substitutes the target's four fields (unchanged), and editing
        // seeds the draft from it.
        let baseline = try Self.sourceBlock(
            in: app,
            startingAt: "private var filterDetailBaseline: AppConfiguration {",
            endingBefore: "var detailFilter: Filter {"
        )
        XCTAssertTrue(baseline.contains("guard let id = filterEditTargetID, let target = library.filter(id: id) else"))
        for field in ["enabledBlocklistIDs", "customBlocklists", "blockedDomains", "allowedDomains"] {
            XCTAssertTrue(baseline.contains("baseline.\(field) = target.\(field)"))
        }
        XCTAssertTrue(app.contains("filterEditDraft = FilterEditDraft(configuration: filterDetailBaseline)"))

        // beginViewingFilterDetail just points the page at a filter — no stale-draft drop, because
        // each filter's draft lives under its own key (opening B never touches A's draft).
        let begin = try Self.sourceBlock(
            in: app,
            startingAt: "func beginViewingFilterDetail(id: String?) {",
            endingBefore: "func endViewingFilterDetail() {"
        )
        XCTAssertTrue(begin.contains("filterEditTargetID = (id == nil || id == library.activeFilterID) ? nil : id"))
        XCTAssertFalse(begin.contains("filterEditDraft = nil"), "Per-filter: opening a filter must not drop another's draft.")

        // endViewingFilterDetail unifies active/non-active: drop a CLEAN draft, keep a DIRTY one in
        // its per-filter slot (resume on re-open), then stop targeting. No active/non-active branch.
        let end = try Self.sourceBlock(
            in: app,
            startingAt: "func endViewingFilterDetail() {",
            endingBefore: "var isFilterEditing: Bool {"
        )
        XCTAssertTrue(end.contains("if !filterDraftHasChanges {"))
        XCTAssertTrue(end.contains("filterEditDraft = nil"))
        XCTAssertTrue(end.contains("filterEditTargetID = nil"))

        // The single-slot guards are GONE: no discard-prediction, no Apply/View discard dialogs, no
        // root-nav reset, no cancelFilterEditingOnPageDisappear.
        XCTAssertFalse(app.contains("filterActionDiscardsUnsavedDraft"))
        XCTAssertFalse(app.contains("resetNonActiveFilterDetailOnRootNavigation"))
        XCTAssertFalse(app.contains("cancelFilterEditingOnPageDisappear"))
        let rootView = try Self.source(named: "RootView.swift", in: "LavaSecApp")
        XCTAssertFalse(rootView.contains("resetNonActiveFilterDetailOnRootNavigation"))

        // Domain History edits the ACTIVE filter's keyed draft (activeFilterDraft) and refuses only
        // when the ACTIVE filter has an unsaved draft (a non-active filter's draft is irrelevant).
        let stage = try Self.sourceBlock(
            in: app,
            startingAt: "func stageDomainHistoryDomainAction(",
            endingBefore: "func removeAllowedDomainFromDraft("
        )
        XCTAssertTrue(stage.contains("if hasUnsavedActiveFilterDraft {"))
        XCTAssertTrue(stage.contains("activeFilterDraft = FilterEditDraft(configuration: result.configuration)"))

        // deleteFilter just drops the deleted filter's keyed draft.
        let delete = try Self.sourceBlock(
            in: app,
            startingAt: "func deleteFilter(id: String) -> Bool {",
            endingBefore: "func restoreFiltersToDefault()"
        )
        XCTAssertTrue(delete.contains("filterEditDrafts[id] = nil"))

        // FiltersView: teardown still driven by the navigation binding (both MyListCover sites), the
        // self-healing onAppear re-assert + dismiss-on-stale are kept, and the discard dialogs +
        // PendingFilterAction are gone.
        let filtersView = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let teardownSites = filtersView.components(separatedBy: "if !presented { viewModel.endViewingFilterDetail() }").count - 1
        XCTAssertEqual(teardownSites, 2, "Both MyListCover navigationDestinations must tear down on dismissal.")
        XCTAssertFalse(filtersView.contains("PendingFilterAction"))
        XCTAssertFalse(filtersView.contains("Discard unsaved changes?"))
        let myList = try Self.sourceBlock(
            in: filtersView,
            startingAt: "private struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )
        XCTAssertFalse(myList.contains(".onDisappear"))
        XCTAssertTrue(myList.contains("let detailTargetID: String?"))
        XCTAssertTrue(myList.contains("if viewModel.filterEditTargetID != detailTargetID {"))
        XCTAssertTrue(myList.contains("if let id = detailTargetID, viewModel.library.filter(id: id) == nil {"))
        XCTAssertTrue(myList.contains("dismiss()"))
    }

    func testNonActiveFilterEditAppliesLibraryOnlyWithNoRecompile() throws {
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // The non-active save is a dedicated method (NOT the active prepareAndApplyFilterDraft
        // path): it returns a message on failure so the caller shows it inline rather than the
        // full-screen preparation cover.
        let nonActive = try Self.sourceBlock(
            in: app,
            startingAt: "func saveNonActiveFilterDraft() -> String? {",
            endingBefore: "// MARK: - Multi-filter library"
        )
        // Library-only: mutateFilter + persistLibraryOnlyChange, invalidates the compiled token.
        XCTAssertTrue(nonActive.contains("library.mutateFilter(id: targetID)"))
        XCTAssertTrue(nonActive.contains("filter.lastCompiledToken = nil"))
        XCTAssertTrue(nonActive.contains("persistLibraryOnlyChange(rollingBackTo: previousLibrary)"))
        // Validation runs but reports inline (returns the message) — no failure cover.
        XCTAssertTrue(nonActive.contains("return validationMessage"))
        // Never compiles, never writes shared state / reloads the tunnel, never presents the cover.
        XCTAssertFalse(nonActive.contains("prepareFilterSnapshot"),
                       "A non-active edit must not compile a snapshot.")
        XCTAssertFalse(nonActive.contains("persistSharedState"),
                       "A non-active edit must not write shared state / reload the tunnel.")
        XCTAssertFalse(nonActive.contains("notifyTunnelSnapshotUpdated"),
                       "A non-active edit must not reload the tunnel.")
        XCTAssertFalse(nonActive.contains("isFilterPreparationScreenPresented = true"),
                       "A non-active edit must not present the full-screen preparation cover.")
        XCTAssertFalse(nonActive.contains("catalogStatusIsError"),
                       "A non-active library-only failure must not flip the global catalog/protection error flag.")

        // The detail page routes a non-active save to this method and shows its message inline.
        let filtersView = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        let saveChanges = try Self.sourceBlock(
            in: filtersView,
            startingAt: "private func saveChanges() {",
            endingBefore: "private enum BlockedDomainSheet"
        )
        XCTAssertTrue(saveChanges.contains("if viewModel.isViewingNonActiveFilter {"))
        XCTAssertTrue(saveChanges.contains("nonActiveSaveError = viewModel.saveNonActiveFilterDraft()"))
    }

    func testPreparationCoverIsOriginScopedAndReSealClearsUploadMarker() throws {
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // Origin-scoped preparation cover: the model tracks which surface owns the shared cover,
        // set at the apply/switch entry points (not at staging, so it can't go stale).
        XCTAssertTrue(app.contains("var filterPreparationOrigin: FilterReviewOrigin"))
        XCTAssertTrue(app.contains("func prepareAndApplyFilterDraft(origin: FilterReviewOrigin"))
        XCTAssertTrue(app.contains("filterPreparationOrigin = origin"))
        let switchBlock = try Self.sourceBlock(
            in: app,
            startingAt: "func switchToFilter(id: String) async {",
            endingBefore: "private func duplicateName(of name: String)"
        )
        XCTAssertTrue(switchBlock.contains("filterPreparationOrigin = .filters"),
                      "A switch is a Filters-tab action and must claim the Filters origin.")

        // Re-seal clears the upload marker so currentState() doesn't report a stale .synced after a
        // local change (Settings would otherwise claim the latest backup is already uploaded).
        let resealBlock = try Self.sourceBlock(
            in: app,
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

        // An in-flight upload must version-check the local envelope before recording .synced, so a
        // re-seal during the upload can't leave a stale "uploaded" marker for the older envelope.
        XCTAssertTrue(app.contains("recordEncryptedBackupUploadIfStillCurrent("),
                      "Upload must only record the marker if the uploaded envelope is still current.")
        let uploadGuard = try Self.sourceBlock(
            in: app,
            startingAt: "private func recordEncryptedBackupUploadIfStillCurrent(",
            endingBefore: "private func scheduleAutomaticBackupAfterConfigurationChange()"
        )
        XCTAssertTrue(uploadGuard.contains("loadLocalEncryptedBackupEnvelope() == uploadedEnvelope"),
                      "The marker guard must compare the uploaded envelope to the current local one.")

        // Domain History applies through the shared review flow with its own origin, and its cover
        // gates on that origin so the always-mounted Filters cover can't steal the presentation.
        let review = try Self.source(named: "FilterReviewFlowView.swift", in: "LavaSecApp")
        XCTAssertTrue(review.contains("prepareAndApplyFilterDraft(origin: origin)"))
        let diagnostics = try Self.source(named: "DiagnosticsView.swift", in: "LavaSecApp")
        XCTAssertTrue(diagnostics.contains("viewModel.filterPreparationOrigin == .domainHistory"),
                      "The Domain History cover must gate on its own origin.")

        // The shared failure screen tailors its affordances: "Try Again" only when the failure is
        // retryable (a deleted/frozen switch target is a dead end), and "Back to Edit"/"Back to
        // Review" only when there's an editor/review to return to (a switch has neither).
        XCTAssertTrue(review.contains("if viewModel.filterPreparationFailureIsRetryable {"),
                      "Try Again must be hidden for a non-retryable (deleted/frozen-target) failure.")
        XCTAssertTrue(review.contains("if viewModel.filterPreparationFailureOffersEditReturn {"),
                      "Back to Edit/Review must be hidden when there's no editor (a filter switch).")
        XCTAssertTrue(app.contains("var filterPreparationFailureOffersEditReturn: Bool {"))
        XCTAssertTrue(app.contains("pendingSwitchFilterID == nil"),
                      "A switch failure (pendingSwitchFilterID set) must not offer the edit return.")
    }

    func testFrozenFiltersAreReadOnlyAndEditModeIsAuthGated() throws {
        let source = try Self.source(named: "FiltersView.swift", in: "LavaSecApp")
        // Frozen (lapsed-Plus) filters are read-only: delete is gated and rename is refused, but
        // they remain VIEWABLE — the dialog drops Apply and opens a read-only View (Codex r6).
        XCTAssertTrue(source.contains("&& !viewModel.isFilterFrozen(filter.id)"),
                      "canDelete must exclude frozen filters.")
        XCTAssertTrue(source.contains("if !isFrozen && !isPendingDeletion { rename() }"),
                      "Rename must be refused for frozen filters (and for a staged-for-delete row).")
        // The Apply button is only offered for non-frozen filters (can't switch to a frozen one).
        XCTAssertTrue(source.contains("if !viewModel.isFilterFrozen(filter.id) {"),
                      "Apply must be hidden for frozen filters.")
        // MyListCover renders a frozen filter read-only: no Edit affordance, and beginEditing is
        // guarded.
        let myList = try Self.sourceBlock(
            in: source,
            startingAt: "private struct MyListCover: View",
            endingBefore: "private enum BlockedDomainSheet"
        )
        XCTAssertTrue(myList.contains("private var isReadOnly: Bool {"))
        XCTAssertTrue(myList.contains("return viewModel.isFilterFrozen(id)"))
        XCTAssertTrue(myList.contains("if !isReadOnly {"),
                      "The Edit affordance must be hidden for a read-only (frozen) filter.")
        XCTAssertTrue(myList.contains("guard !isReadOnly else { return }"),
                      "beginEditing must refuse a read-only (frozen) filter.")
        // If a filter became frozen (Plus lapsed) while a draft was preserved, the page must drop
        // the draft on appear (read-only view) and the save path must report it, not silently no-op.
        XCTAssertTrue(myList.contains("if isReadOnly, viewModel.filterEditDraft != nil {"),
                      "A now-frozen filter must drop its preserved draft on appear.")
        let app = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let save = try Self.sourceBlock(
            in: app,
            startingAt: "func saveNonActiveFilterDraft() -> String? {",
            endingBefore: "// MARK: - Multi-filter library"
        )
        XCTAssertTrue(save.contains("guard !isFilterFrozen(targetID) else {"),
                      "Saving a frozen target must return a locked message, not nil.")

        // Entering library edit mode (add/rename/delete) is gated on the filter-editing
        // surface, like My filter's edit entry point — auth must precede isEditing = true.
        let editButton = try Self.sourceBlock(in: source, startingAt: "accessibilityLabel: \"Edit\") {", endingBefore: ".navigationDestination(")
        let authIdx = try XCTUnwrap(editButton.range(of: "requireAuthentication(")?.lowerBound)
        let enterIdx = try XCTUnwrap(editButton.range(of: "isEditing = true")?.lowerBound)
        XCTAssertLessThan(authIdx, enterIdx, "Auth must gate entering edit mode.")
        XCTAssertTrue(editButton.contains("for: .filterEditing"))
    }

    // MARK: - Helpers

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func sourceBlock(
        in source: String,
        startingAt startMarker: String,
        endingBefore endMarker: String
    ) throws -> String {
        let start = try XCTUnwrap(source.range(of: startMarker)?.lowerBound)
        let suffix = source[start...]
        let end = try XCTUnwrap(suffix.range(of: endMarker)?.lowerBound)
        return String(suffix[..<end])
    }
}
