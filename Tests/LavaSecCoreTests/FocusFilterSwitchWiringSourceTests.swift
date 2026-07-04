import XCTest

/// Structural invariants for the Focus-driven headless warm switch. The switch ENGINE now lives in
/// LavaSecCore (`HeadlessFocusFilterSwitchEngine`, LAV-100 Phase 4 — relocated out of the app target so
/// the App Intents extension can drive it with no `AppViewModel`); the foreground reconcile + the
/// foreground-activity publisher + the manual `switchToFilter` stay in `AppViewModel`. The engine has
/// real unit tests (`HeadlessFocusFilterSwitchEngineTests`); these pin its safety-critical wiring as
/// source text (the app-target reconcile is not reachable from `swift test`).
final class FocusFilterSwitchWiringSourceTests: XCTestCase {
    /// The engine's decision body (gate → guards → marker → hybrid defer/commit). Stops before the
    /// commit helper.
    private static func runLockedBlock() throws -> String {
        try sourceBlock(
            in: try readSource(.headlessFocusFilterSwitchEngine),
            startingAt: "private static func runLocked(toFilterID id: String, env: Environment) async",
            endingBefore: "// MARK: - Commit"
        )
    }

    func testHeadlessSwitchGatesFailClosedThenRecordsMarkerThenDefersOrCommits() throws {
        let block = try Self.runLockedBlock()

        // Fail-closed SECURITY boundary: NOT auth-to-edit. Focus auto-switch is available to ALL tiers, so
        // the gate must NOT Plus-gate (the paywall was dropped).
        XCTAssertFalse(block.contains("guard configuration.hasLavaSecurityPlus"),
                       "The headless switch gate must NOT Plus-gate — Focus auto-switch is free for all tiers.")
        XCTAssertTrue(block.contains("SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults)"))

        // A reseeded/migrated load (or a failed config load) must refuse — committing would write default
        // rules/settings over the user's real state (mirrors the bg-refresh bg-premigration bail).
        XCTAssertTrue(block.contains("guard !loaded.didReseed else { return SwitchDecision(.disallowed, \"disallowed-config-fallback-or-reseed\") }"),
                      "The headless switch must bail on a reseeded/config-fallback library (no default clobber).")

        // A final catalog re-validation before the flip (mirrors the foreground's catalog-moved guard).
        XCTAssertTrue(block.contains("WarmFilterSnapshotLoader.stillReusableAgainstCachedCatalog("),
                      "The headless commit must re-validate the warm snapshot against the current cached catalog before flipping.")

        // Seven foreground-nudge sites (the two foreground-active defer guards were removed — the switch is
        // state-agnostic now): already-active + plan-unavailable + no-warm + catalog-moved-prevalidation +
        // the COMMITTED branch (Codex P1: a commit can now land while the app is foreground-active, so it must
        // wake the resident reconcile too) + the catalog-moved CLEAN-DEFER catch arm + the generation-superseded
        // CLEAN-DEFER catch arm. The GENERIC commit-failure catch does NOT nudge.
        XCTAssertEqual(
            block.components(separatedBy: "env.postSignal(FocusFilterSwitchSignal.darwinNotificationName)").count - 1,
            7,
            "already-active + 3 early defers + committed + catalog-moved + generation-superseded must post the foreground nudge."
        )
        // The superseding-writer clean-defer arm (P4c review P2): a concurrent newer writer — caught at the
        // flip fence (SupersededError) OR the stale-base write fence (StaleBaseGenerationError) — defers
        // WITHOUT rolling back, so it can't clobber the newer on-disk state. Distinct from catalog-moved +
        // the generic wedge.
        XCTAssertTrue(block.contains("supersedingWriterError is SupersededError")
                        && block.contains("supersedingWriterError is SharedFilterStatePersistence.StaleBaseGenerationError"),
                      "One clean-defer arm must handle BOTH the superseded flip and the stale-base write abort.")
        XCTAssertTrue(block.contains("\"headless-commit-deferred-superseded\""),
                      "The superseding-writer clean-defer path must log a distinct event.")
        // The fences live in the commit helper: the in-lock flip fence (commitBeforeFlip) + the generation
        // CAS on the config write.
        let fenceBlock = try sourceBlock(
            in: try readSource(.headlessFocusFilterSwitchEngine),
            startingAt: "private static func commit(",
            endingBefore: "private static func writeConfigurationOnly("
        )
        XCTAssertTrue(fenceBlock.contains("SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) <= writtenGeneration"),
                      "The in-lock fence must abort the flip if a concurrent writer advanced the generation past ours.")
        XCTAssertTrue(fenceBlock.contains("throw SupersededError()"),
                      "The fence must throw SupersededError to abort the flip before it happens.")
        XCTAssertTrue(fenceBlock.contains("rejectsAdvancedBeyond: configuration.configurationGeneration"),
                      "The forward config write must fence against the loaded base so a concurrent foreground write isn't clobbered.")
        // The generation fence must run BEFORE the catalog-basis veto, so a coinciding supersession + catalog
        // move defers WITHOUT rolling back (SupersededError wins → the newer foreground config is preserved).
        let fenceOrderIdx = try XCTUnwrap(fenceBlock.range(of: "throw SupersededError()")?.lowerBound)
        let vetoCallIdx = try XCTUnwrap(fenceBlock.range(of: "try commitBeforeFlip()")?.lowerBound)
        XCTAssertLessThan(fenceOrderIdx, vetoCallIdx,
                          "The SupersededError generation fence must be evaluated before the catalog-basis veto call.")
        let catchBlock = try sourceBlock(in: block, startingAt: "} catch {", endingBefore: "deferred-commit-failed")
        // Uniqueness guard: the body has THREE catch arms — the specialized
        // `} catch is CatalogMovedError {` (clean defer), the generic `} catch {`, and the nested
        // `} catch let rollbackError {`. The `} catch {` anchor must extract the GENERIC arm.
        XCTAssertTrue(catchBlock.contains("} catch let rollbackError {"),
                      "The extracted block must be the GENERIC commit-failure catch (it owns the nested rollback do/catch).")
        XCTAssertFalse(catchBlock.contains("env.postSignal("),
                       "The generic catch returns .deferred without a nudge (the foreground reconcile picks it up).")
        // Rollback observability.
        XCTAssertTrue(catchBlock.contains("env.log(\"headless-commit-failed-rolled-back\""),
                      "A failed-then-rolled-back commit must be logged.")
        XCTAssertTrue(catchBlock.contains("env.log(\"headless-commit-rollback-failed\""),
                      "A commit whose rollback ALSO failed (the wedge) must be logged.")

        // The gate must fail-closed BEFORE anything is recorded.
        let gateIdx = try XCTUnwrap(block.range(of: "SecurityProtectedSurfaceStorage.isProtected(.filterEditing")?.lowerBound)
        let recordIdx = try XCTUnwrap(block.range(of: "PendingFilterSwitchStore.record(request, in: defaults")?.lowerBound)
        XCTAssertLessThan(gateIdx, recordIdx, "The auth-to-edit gate must precede recording the marker.")
        // TWO record sites: the main path AND the already-active path (records the newest intent).
        XCTAssertEqual(block.components(separatedBy: "PendingFilterSwitchStore.record(").count - 1, 2,
                       "The already-active path must also record the newest intent (supersede a stale marker).")
        let alreadyActiveRecordIdx = try XCTUnwrap(block.range(of: "PendingFilterSwitchStore.record(PendingFilterSwitchRequest(targetFilterID: id")?.lowerBound)
        XCTAssertLessThan(gateIdx, alreadyActiveRecordIdx, "The gate must precede the already-active record site as well.")
        // The main path FAILS CLOSED if the marker write fails.
        XCTAssertTrue(block.contains("guard PendingFilterSwitchStore.record(request, in: defaults"),
                      "A failed marker write on the main path must fail closed (return .disallowed).")

        // STATE-AGNOSTIC: the headless switch must NOT gate on a foreground-active flag (that 5-min defer was
        // dropped — the cross-process CAS makes a concurrent foreground write safe, so it commits regardless
        // of app state). The whole AppForegroundActivityState machinery is gone.
        XCTAssertFalse(block.contains("AppForegroundActivityState"),
                       "The headless switch must not consult any foreground-active flag (state-agnostic).")
        XCTAssertFalse(block.contains("isForegroundActive"),
                       "No foreground-active defer remains — the switch is state-agnostic via the CAS.")

        // WARM-ONLY: the headless path must NEVER cold-compile.
        XCTAssertFalse(block.contains("prepareFilterSnapshot("),
                       "The headless switch must be warm-only — no cold compile.")
        XCTAssertTrue(block.contains("WarmFilterSnapshotLoader.reusableSnapshotForSwitch("),
                      "The warm artifact must be resolved via the shared loader against the TARGET's mirrored config (plan).")
        XCTAssertTrue(block.contains("configuration: plan.configuration"),
                      "Warm validation must use the plan's (target's) configuration, not the active config.")

        // Commit via the SHARED publish path (config-leads-pointer + pointer flip) and post the tunnel reload.
        XCTAssertTrue(block.contains("FilterSwitchPlan.make(toFilterID: id, configuration: configuration, library: library)"))
        XCTAssertTrue(block.contains("configuration = plan.configuration"),
                      "The headless commit must take configuration from the plan.")
        XCTAssertTrue(block.contains("library = plan.library"),
                      "The headless commit must take the library from the same plan (not re-mutate a live library).")
        XCTAssertTrue(block.contains("try await commit("),
                      "The headless commit must go through the shared commit helper.")
        // The commit must pass an IN-LOCK catalog-basis veto.
        XCTAssertTrue(block.contains("commitBeforeFlip: { @Sendable in"),
                      "The headless commit must pass an in-lock commitBeforeFlip catalog-basis veto.")
        XCTAssertTrue(block.contains("throw CatalogMovedError()"),
                      "The in-lock veto must throw CatalogMovedError when the catalog basis moved.")
        XCTAssertTrue(block.contains("canReuseForProtectionStartup(configuration: basisConfiguration, cachedCatalog: cachedCatalog)"),
                      "The in-lock veto must re-validate the warm snapshot's basis against the freshly-loaded cached catalog.")
        XCTAssertTrue(block.contains("catch is CatalogMovedError {"),
                      "The catalog-moved veto must be caught as a clean defer, distinct from the generic commit-failure wedge.")
        XCTAssertTrue(block.contains("\"headless-commit-deferred-catalog-moved\""),
                      "The clean-defer path must log a distinct catalog-moved event (not a wedge error).")
        // A committed switch does NOT push to the tunnel — the always-on tunnel adopts it by polling the
        // config generation (P4d), since an extension→idle-tunnel Darwin is unreliable. So the only Darwin
        // the engine ever posts is the foreground reconcile nudge.
        XCTAssertFalse(block.contains("tunnelReloadDarwinName"),
                       "The engine must NOT post a tunnel-reload Darwin (the tunnel poll adopts the commit).")

        // The commit helper funnels through the single shared writer + the shared artifact publish.
        let commitBlock = try sourceBlock(
            in: try readSource(.headlessFocusFilterSwitchEngine),
            startingAt: "private static func commit(",
            endingBefore: "private static func writeConfigurationOnly("
        )
        XCTAssertTrue(commitBlock.contains("SharedFilterStatePersistence.writeConfigurationAndLibrary("),
                      "The commit must write config+library through the single shared writer (config leads pointer).")
        XCTAssertTrue(commitBlock.contains("service.persistArtifacts("),
                      "The commit must publish + flip the artifact pointer through the shared service.")
        // The headless model never loaded the backup state, so the engine must NEVER schedule a backup.
        XCTAssertFalse(commitBlock.contains("scheduleAutomaticBackup"),
                       "The headless engine must not touch automatic-backup scheduling (state not loaded).")
    }

    func testHeadlessSwitchNeverClearsMarkerAndFencesRollback() throws {
        let block = try Self.runLockedBlock()
        // The headless path NEVER clears the marker (the foreground reconcile is the sole clearer).
        XCTAssertFalse(block.contains("clearIfMatches"),
                       "The headless path must not clear the pending-switch marker (foreground reconcile is the sole clearer).")
        // A partial commit is rolled back to the previous filter so the on-disk selection stays consistent
        // with the un-flipped pointer.
        let catchIdx = try XCTUnwrap(block.range(of: "} catch {")?.lowerBound)
        let catchBody = String(block[catchIdx...])
        XCTAssertTrue(catchBody.contains("configuration = previousConfiguration"))
        XCTAssertTrue(catchBody.contains("library = previousLibrary"))
        XCTAssertTrue(catchBody.contains("writeConfigurationOnly("),
                      "A failed headless commit must roll the on-disk selection back to the previous filter.")
        // The rollback must be FENCED against our own write so it can't clobber a newer foreground write that
        // landed in the gap between the config write and the rollback (panel P1).
        XCTAssertTrue(catchBody.contains("let fencedGeneration = configuration.configurationGeneration"),
                      "The generic rollback must capture the generation we wrote to fence the revert.")
        XCTAssertTrue(catchBody.contains("expectedBaseGeneration: fencedGeneration"),
                      "The generic rollback must pass the fenced generation so a newer foreign write isn't clobbered.")
        XCTAssertTrue(catchBody.contains("catch is SharedFilterStatePersistence.StaleBaseGenerationError"),
                      "A rollback superseded by a newer write must be a benign skip, not logged as a wedge.")
        // The catalog-moved clean-defer arm must fence its rollback the same way.
        let catalogArm = try sourceBlock(in: block, startingAt: "} catch is CatalogMovedError {", endingBefore: "} catch let supersedingWriterError")
        XCTAssertTrue(catalogArm.contains("expectedBaseGeneration: fencedGeneration"),
                      "The catalog-moved rollback must also fence against our own write.")
    }

    func testForegroundReconcileAppliesThenCompareAndClears() throws {
        let app = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: app,
            startingAt: "func reconcilePendingFilterSwitch() async {",
            endingBefore: "private func persistSharedState("
        )
        XCTAssertTrue(block.contains("guard !isHeadless else { return }"),
                      "Reconcile is foreground-only.")
        XCTAssertTrue(block.contains("guard !isReconcilingPendingFilterSwitch else {"),
                      "Reconcile must guard against overlapping runs.")
        XCTAssertTrue(block.contains("pendingReconcileRerun = true"),
                      "A blocked wake trigger must request a rerun.")
        XCTAssertTrue(block.contains("} while pendingReconcileRerun"),
                      "The in-flight reconcile must loop while a rerun is pending.")
        XCTAssertTrue(block.contains("var remainingReconcilePasses = 2"),
                      "Each synchronous drain must be bounded to the initial pass + one rerun.")
        XCTAssertTrue(block.contains("if pendingReconcileRerun {"),
                      "After the bounded loop, a still-queued rerun must be handled, not dropped.")
        XCTAssertTrue(block.contains("Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }"),
                      "A queued rerun left at the cap must re-dispatch a fresh reconcile (Codex round-17).")
        XCTAssertTrue(block.contains("PendingFilterSwitchStore.current(in: defaults)"))
        XCTAssertTrue(block.contains("await switchToFilter(id: request.targetFilterID, stampsForegroundSwitch: false)"),
                      "Reconcile must apply via switchToFilter WITHOUT stamping the foreground-switch timestamp.")
        XCTAssertTrue(block.contains("logFocusSwitchEvent(\"reconcile-apply\""),
                      "Reconcile must log each apply for failure-loop observability.")

        XCTAssertFalse(block.contains("guard configuration.hasLavaSecurityPlus"),
                       "Reconcile must NOT Plus-gate the apply — Focus auto-switch is free for all tiers.")
        XCTAssertTrue(block.contains("SecurityProtectedSurfaceStorage.isProtected(.filterEditing, defaults: defaults)"))
        let gateIdx = try XCTUnwrap(block.range(of: "SecurityProtectedSurfaceStorage.isProtected(.filterEditing")?.lowerBound)
        XCTAssertTrue(block.contains("PendingFilterSwitchStore.lastForegroundSwitch(in: defaults)"))
        XCTAssertTrue(block.contains("request.requestedAt <= lastForegroundSwitchAt"))
        let staleDropIdx = try XCTUnwrap(block.range(of: "request.requestedAt <= lastForegroundSwitchAt")?.lowerBound)
        XCTAssertTrue(block.contains("scheduleAutomaticBackupAfterConfigurationChange()"),
                      "Reconcile must schedule the backup for a headless-committed (already-active) change.")
        let alreadyActiveIdx = try XCTUnwrap(block.range(of: "scheduleAutomaticBackupAfterConfigurationChange()")?.lowerBound)
        let notifyIdx = try XCTUnwrap(block.range(of: "await notifyTunnelSnapshotUpdated()", range: alreadyActiveIdx..<block.endIndex)?.lowerBound)
        let alreadyActiveClearIdx = try XCTUnwrap(block.range(of: "PendingFilterSwitchStore.clearIfMatches(request, in: defaults", range: alreadyActiveIdx..<block.endIndex)?.lowerBound)
        XCTAssertLessThan(notifyIdx, alreadyActiveClearIdx,
                          "The already-active branch must re-notify the tunnel BEFORE clearing the marker.")

        let applyIdx = try XCTUnwrap(block.range(of: "await switchToFilter(id: request.targetFilterID, stampsForegroundSwitch: false)")?.lowerBound)
        XCTAssertLessThan(gateIdx, applyIdx, "The gate + supersession checks must precede applying the switch.")
        XCTAssertLessThan(staleDropIdx, applyIdx, "The stale-marker supersession check must precede applying the switch.")
        XCTAssertTrue(block.contains("guard !isForegroundManualSwitchInFlight else {"),
                      "Reconcile must not apply while a manual switch is in flight (round-18).")
        XCTAssertTrue(block.contains("\"reconcile-deferred-manual-switch-in-flight\""),
                      "The in-flight-manual-switch deferral must be logged.")
        let inFlightDeferIdx = try XCTUnwrap(block.range(of: "guard !isForegroundManualSwitchInFlight else {")?.lowerBound)
        XCTAssertLessThan(inFlightDeferIdx, applyIdx, "The in-flight-manual-switch deferral must precede the apply.")
        XCTAssertTrue(block.contains("guard library.activeFilterID == request.targetFilterID else {"),
                      "Reconcile must verify the switch took effect before clearing the marker.")
        let successGuardIdx = try XCTUnwrap(block.range(of: "guard library.activeFilterID == request.targetFilterID else {", range: applyIdx..<block.endIndex)?.lowerBound)
        let clearIdx = try XCTUnwrap(block.range(of: "PendingFilterSwitchStore.clearIfMatches(request, in: defaults", range: successGuardIdx..<block.endIndex)?.lowerBound)
        XCTAssertLessThan(applyIdx, successGuardIdx, "The success check must follow the apply.")
        XCTAssertLessThan(successGuardIdx, clearIdx, "The marker is cleared only after confirming the switch took effect.")

        // ADOPT a cross-process (extension) commit before deciding: when the on-disk generation is NEWER than
        // ours, the extension switched the filter on disk while this resident app was suspended. Reload to
        // adopt it, then — only on an ACTUAL active-filter change — run the full warm-switch tail. Otherwise
        // the already-active check compares stale in-memory state and cold-recompiles (recompile-on-return).
        XCTAssertTrue(block.contains("SharedFilterStatePersistence.onDiskConfigurationGeneration(at: configurationURL) > configuration.configurationGeneration"),
                      "Reconcile must detect a newer on-disk generation (a cross-process commit) before deciding.")
        // Adopt only a COMPLETED commit: the pointer (flipped LAST) must name the on-disk active filter's
        // artifact. CRUCIALLY this is a guard→return (DEFER), not an if-condition (fall-through): a mid-commit
        // (config-leads-pointer) state must NOT fall through to switchToFilter below, which would race the
        // extension's in-flight commit and cold-recompile (Codex P2). The kept marker + next reconcile adopt it.
        XCTAssertTrue(block.contains("guard let pointerToken = FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token,")
                        && block.contains("SharedFilterStatePersistence.onDiskActiveFilterCompiledToken(at: filterLibraryURL) == pointerToken"),
                      "The completeness check must be a guard (defer-on-incomplete), requiring the pointer to name the on-disk active filter's token.")
        XCTAssertTrue(block.contains("loadPersistedConfiguration()"),
                      "Reconcile must reload persisted state to adopt a newer on-disk commit.")
        // Re-validate completeness AFTER the reload (closes the check-then-reload TOCTOU: a back-to-back commit
        // can land between the pre-check and the reload). If disk is mid-commit, defer (return) — don't act.
        XCTAssertTrue(block.contains("guard library.filter(id: library.activeFilterID)?.lastCompiledToken")
                        && block.contains("== FilterArtifactStore(directoryURL: containerURL).loadArtifactPointer()?.token else {"),
                      "The adopt must re-validate the reloaded active filter's token against the live pointer and defer if mid-commit.")
        let adoptIdx = try XCTUnwrap(block.range(of: "loadPersistedConfiguration()")?.lowerBound)
        XCTAssertLessThan(adoptIdx, alreadyActiveIdx, "The disk adopt must precede the already-active check.")
        XCTAssertLessThan(adoptIdx, applyIdx, "The disk adopt must precede the switchToFilter fallback.")
        let adoptGateIdx = try XCTUnwrap(block.range(of: "if !isForegroundManualSwitchInFlight,")?.lowerBound)
        XCTAssertLessThan(adoptGateIdx, adoptIdx, "The disk adopt must be skipped while a user switch is in flight.")
        XCTAssertTrue(block.contains("let previousActiveID = library.activeFilterID"),
                      "The adopt must capture the pre-load active filter id to detect a real change.")
        // Gate on an ACTUAL active-filter change (Codex P2): a bare gen-bump rollback (active unchanged) must
        // be a no-op, else a superseded-then-failed switch leaves the rehydration flag stuck.
        XCTAssertTrue(block.contains("if library.activeFilterID != previousActiveID {"),
                      "The tail must run only when the adopt actually changed the active filter.")
        XCTAssertTrue(block.contains("await applyCommittedOnDiskActiveFilter(adoptToken: adoptToken, shouldRestoreProtection: shouldRestoreProtection)"),
                      "On an actual active-filter change the adopt must run the full warm-switch tail.")
        XCTAssertTrue(block.contains("let adoptToken = configurationReplacementGate.begin()"),
                      "The adopt tail must run under a fresh replacement epoch (begin() — no preparation cover, no recompile).")

        // The adopt TAIL mirrors switchToFilter's warm tail (NOT a piecemeal patch — Codex found 4 gaps doing
        // it piecemeal): apply the on-disk warm snapshot synchronously, rehydrate per-source caches, clear the
        // non-active detail target, notify the tunnel, restore protection. NO persistSharedState (the extension
        // already persisted + flipped) and NO lastForegroundSwitch stamp.
        let adoptTail = try sourceBlock(
            in: app,
            startingAt: "private func applyCommittedOnDiskActiveFilter(",
            endingBefore: "// The headless Focus warm-switch orchestration"
        )
        XCTAssertTrue(adoptTail.contains("warmReusableSnapshotForSwitch(target: target, configuration: configuration)")
                        && adoptTail.contains("applyReusablePreparedSnapshot(reusable)"),
                      "The adopt tail must apply the on-disk filter's warm snapshot synchronously.")
        XCTAssertTrue(adoptTail.contains("configurationReplacementGate.isCurrent(adoptToken)"),
                      "The adopt tail must bail if a newer switch superseded it during the async warm load.")
        XCTAssertTrue(adoptTail.contains("hasPendingWarmSwitchCacheRehydration = true")
                        && adoptTail.contains("rehydrateRuleSetCachesAfterWarmSwitch(switchToken: adoptToken"),
                      "The adopt tail must defer in-place edits + rehydrate the per-source caches.")
        XCTAssertTrue(adoptTail.contains("filterEditTargetID = nil"),
                      "The adopt tail must clear the non-active detail target so the now-active filter isn't treated as non-active.")
        XCTAssertTrue(adoptTail.contains("await notifyTunnelSnapshotUpdated()")
                        && adoptTail.contains("await restoreProtectionIfNeeded(wasEnabled: shouldRestoreProtection)"),
                      "The adopt tail must notify the tunnel + restore protection (mirrors switchToFilter's tail).")
        XCTAssertFalse(adoptTail.contains("persistSharedState(") || adoptTail.contains("recordForegroundSwitch("),
                       "The adopt tail must NOT re-persist or stamp lastForegroundSwitch — the extension already committed.")
        // Canary: the negative pins above key on these identifiers - if a rename removes
        // one from the pinned source, those pins pass vacuously. Fail here instead, then
        // re-anchor both sides to the new name.
        XCTAssertTrue(app.contains("hasLavaSecurityPlus"))
    }

    func testForegroundSwitchStampIsGuardedAndSingleSited() throws {
        let app = try readSource(.appViewModel)
        XCTAssertTrue(app.contains("func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async"),
                      "switchToFilter must accept a stampsForegroundSwitch flag (default true for genuine user switches).")
        XCTAssertTrue(app.contains("if stampsForegroundSwitch {"),
                      "The lastForegroundSwitch stamp must be guarded so a reconcile-driven apply can't poison it.")
        XCTAssertEqual(app.components(separatedBy: "PendingFilterSwitchStore.recordForegroundSwitch(").count - 1, 1,
                       "Exactly one stamp site (inside switchToFilter, guarded) — no other path may stamp.")
        let switchBlock = try sourceBlock(
            in: app,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "private enum SwitchPublication"
        )
        let persistIdx = try XCTUnwrap(switchBlock.range(of: "try await persistSharedState(preparedSnapshot: publication.preparedSnapshot)")?.lowerBound)
        let postPersistGateIdx = try XCTUnwrap(switchBlock.range(of: "guard configurationReplacementGate.isCurrent(switchToken) else {", range: persistIdx..<switchBlock.endIndex)?.lowerBound)
        let stampIdx = try XCTUnwrap(switchBlock.range(of: "PendingFilterSwitchStore.recordForegroundSwitch(")?.lowerBound)
        XCTAssertLessThan(persistIdx, stampIdx, "The stamp must follow the persist (only stamp a switch that durably landed).")
        XCTAssertLessThan(postPersistGateIdx, stampIdx, "The stamp must follow the post-persist gate re-check (only stamp a switch that still owns the gate).")
        XCTAssertTrue(switchBlock.contains("PendingFilterSwitchStore.recordForegroundSwitch(at: switchInitiatedAt"),
                      "The stamp must use the captured initiation instant (switchInitiatedAt), not completion time.")
        XCTAssertFalse(switchBlock.contains("PendingFilterSwitchStore.recordForegroundSwitch(at: Date()"),
                       "The stamp must NOT use a fresh Date() at the commit point (that is completion, not initiation, time).")
        let initiatedCaptureIdx = try XCTUnwrap(switchBlock.range(of: "let switchInitiatedAt = Date()")?.lowerBound)
        let firstPrepareIdx = try XCTUnwrap(switchBlock.range(of: "try await prepareSwitchPublication(")?.lowerBound)
        XCTAssertLessThan(initiatedCaptureIdx, firstPrepareIdx,
                          "switchInitiatedAt must be captured BEFORE the async prepare so it reflects when the user started the switch.")
        XCTAssertLessThan(initiatedCaptureIdx, stampIdx, "The initiation instant must be captured before it is stamped.")
        XCTAssertTrue(switchBlock.contains("isForegroundManualSwitchInFlight = true"),
                      "A genuine user switch must mark itself in flight so the reconcile defers to it (round-18).")
        XCTAssertTrue(switchBlock.contains("isForegroundManualSwitchInFlight = false"),
                      "The in-flight flag must be cleared on exit (defer).")
        XCTAssertTrue(switchBlock.contains("Task { @MainActor [weak self] in await self?.reconcilePendingFilterSwitch() }"),
                      "switchToFilter must re-dispatch a reconcile on exit so a deferred Focus marker isn't stranded (round-18).")
        let inFlightSetIdx = try XCTUnwrap(switchBlock.range(of: "isForegroundManualSwitchInFlight = true")?.lowerBound)
        XCTAssertLessThan(inFlightSetIdx, firstPrepareIdx,
                          "The in-flight flag must be set BEFORE the async prepare (so a reconcile during prepare sees it).")
    }

    func testForegroundActiveMachineryIsRemoved() throws {
        // The state-agnostic switch (no 5-min defer) means the whole foreground-active flag machinery is
        // gone — the app no longer tracks/publishes it. Pin its removal so it can't be reintroduced.
        let app = try readSource(.appViewModel)
        XCTAssertFalse(app.contains("setForegroundActive("),
                       "The foreground-active flag is gone — the headless switch is state-agnostic now.")
        XCTAssertFalse(app.contains("refreshForegroundActivityPublication"),
                       "The foreground-active publisher must be removed.")
        XCTAssertFalse(app.contains("foregroundActivityHeartbeatTask"),
                       "The 60s foreground-active heartbeat must be removed (it wrote an unread flag).")
        XCTAssertFalse(app.contains("markAppForegroundActivity"),
                       "markAppForegroundActivity must be removed.")
        let core = try readSource(.focusFilterSwitchCoordination)
        XCTAssertFalse(core.contains("public enum AppForegroundActivityState"),
                       "The AppForegroundActivityState type must be removed.")
    }

    func testForegroundWarmAndReconcileWiredToScenePhase() throws {
        let root = try readSource(.rootView)
        XCTAssertFalse(root.contains("markAppForegroundActivity"),
                       "RootView must no longer set a foreground-active flag (state-agnostic switch).")
        // Becoming active + on appear keep the non-active filters warm so a closed-app switch commits instantly.
        XCTAssertEqual(root.components(separatedBy: "viewModel.warmNonActiveFiltersOnAppForeground()").count - 1, 2,
                       "Becoming active and on appear must warm the non-active filters.")
        XCTAssertTrue(root.contains("await viewModel.reconcilePendingFilterSwitch()"),
                      "A pending Focus switch must be reconciled when the app foregrounds.")
    }

    /// `logFocusSwitchEvent` is called UNCONDITIONALLY from the foreground reconcile, so its DECLARATION
    /// must sit outside every `#if` (only its body may be gated) — otherwise a Release build drops the
    /// declaration and fails to compile.
    func testLogFocusSwitchEventDeclaredOutsideAnyConditionalCompilation() throws {
        let app = try readSource(.appViewModel)
        var depth = 0
        var found = false
        var foundAtDepthZero = false
        for rawLine in app.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("private func logFocusSwitchEvent(") {
                found = true
                foundAtDepthZero = (depth == 0)
            }
            if line.hasPrefix("#if") {
                depth += 1
            } else if line.hasPrefix("#endif") {
                depth -= 1
            }
        }
        XCTAssertTrue(found, "logFocusSwitchEvent must exist.")
        XCTAssertTrue(foundAtDepthZero,
                      "logFocusSwitchEvent's declaration must be OUTSIDE any #if (only its body gated) or Release won't compile.")
    }

    /// `PendingFilterSwitchStore`'s compare-and-clear is safe ONLY because every IN-APP mutator runs on
    /// the @MainActor. The extension adds a SECOND writer process, so the doc must flag that the
    /// cross-process safety now rests on the focus-switch flock + the marker semantics; pin that the
    /// invariant stays documented (review #5).
    func testPendingSwitchStoreSerializationInvariantIsDocumented() throws {
        let coord = try readSource(.focusFilterSwitchCoordination)
        // The marker's record (extension process) + clearIfMatches (foreground) now take a shared flock so
        // the cross-process record-vs-clear TOCTOU can't drop a just-recorded request (Codex P2). Pin both
        // the shared lock parameter and that the invariant stays documented.
        XCTAssertTrue(coord.contains("FilterPublishLock.withExclusiveLock(at: lockURL)"),
                      "record + clearIfMatches must run under the shared marker flock.")
        XCTAssertEqual(coord.components(separatedBy: "FilterPublishLock.withExclusiveLock(at: lockURL)").count - 1, 2,
                       "Both record AND clearIfMatches must take the shared marker flock.")
        XCTAssertTrue(coord.contains("App Intents EXTENSION as a second"),
                      "The doc must flag that the extension is a second writer process (why the flock is needed).")
        // The app side resolves the SAME lock file the engine/extension uses.
        let app = try readSource(.appViewModel)
        XCTAssertTrue(app.contains("lockURL: pendingFilterSwitchMarkerLockURL"),
                      "The foreground reconcile must pass the shared marker lock to clearIfMatches.")
        XCTAssertTrue(app.contains("LavaSecAppGroup.pendingFilterSwitchMarkerLockFilename"),
                      "The app must resolve the shared marker lock file constant.")
    }

    func testFocusSwitchEntryDrivesTheSharedEngineThroughOneFactory() throws {
        // The single entry: FocusSwitchEnvironment (Shared/, compiled into BOTH the app and the extension)
        // builds the engine environment and drives the SAME LavaSecCore engine — no app-target reimpl.
        let envFactory = try readSource(.focusSwitchEnvironment)
        XCTAssertTrue(envFactory.contains("static func performSwitch(toFilterID filterID: String) async -> HeadlessFocusSwitchOutcome"),
                      "FocusSwitchEnvironment must expose the single performSwitch entry.")
        XCTAssertTrue(envFactory.contains("HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: filterID, env: env)"),
                      "FocusSwitchEnvironment.performSwitch must drive the shared core engine.")
        XCTAssertTrue(envFactory.contains("LavaSecAppGroup.focusFilterSwitchLockFilename"),
                      "The environment must wire the dedicated focus-switch lock file.")
        XCTAssertTrue(envFactory.contains("LavaSecAppGroup.configurationWriteLockFilename"),
                      "The environment must wire the cross-process config-write lock (P4c).")

        // The dedicated cross-process flock that serializes concurrent headless switches lives IN the
        // engine, so the extension gets it (no app-target dependency).
        let engine = try readSource(.headlessFocusFilterSwitchEngine)
        XCTAssertTrue(engine.contains("flock(descriptor, LOCK_EX)"),
                      "The engine must serialize concurrent headless switches with an exclusive flock.")
        XCTAssertTrue(engine.contains("open(lockURL.path, O_CREAT | O_RDWR"),
                      "O_CREAT only (never createFile) so the flock binds to a shared inode.")

        // The dead app-target LavaWarmSwitchService must be gone (the extension calls the engine directly).
        let app = try readSource(.appViewModel)
        XCTAssertFalse(app.contains("enum LavaWarmSwitchService"),
                       "LavaWarmSwitchService must be removed — the App Intents extension drives the engine directly.")
    }

    /// The headless poster and the foreground observer MUST use the same source constants for the Darwin
    /// names, or a rename would silently desync them. The foreground observer + the foreground reconcile
    /// nudge name stay in the app; the engine posts both the foreground nudge and the tunnel-reload name.
    func testDarwinNudgeObserverAndPosterShareTheConstant() throws {
        let app = try readSource(.appViewModel)
        XCTAssertTrue(app.contains("focusPendingSwitchObserver = DarwinNotificationObserver("),
                      "The foreground reconcile observer must be registered.")
        XCTAssertTrue(app.contains("name: FocusFilterSwitchSignal.darwinNotificationName"),
                      "The foreground reconcile observer must register the shared Darwin name constant.")
        // The engine's default poster uses the shared core Darwin notifier; the engine posts both names.
        let engine = try readSource(.headlessFocusFilterSwitchEngine)
        XCTAssertTrue(engine.contains("DarwinProtectionSignalNotifier().postNotification(named: $0)"),
                      "The engine's default signal poster must use the shared core Darwin notifier.")
        XCTAssertTrue(engine.contains("FocusFilterSwitchSignal.darwinNotificationName"),
                      "The engine must post the shared foreground-nudge name on defer.")
    }

    /// P4d: the always-on tunnel adopts a Focus-committed switch by POLLING the on-disk configuration
    /// generation (an extension→idle-tunnel Darwin is unreliable — 0/14 device probes). Pin the dedicated
    /// poll: a ~60s timer, started on tunnel-up and stopped on tunnel-down, that reloads through the
    /// EXISTING reload entry when the generation advances — and assert NO Darwin observer was reintroduced.
    func testTunnelPollsConfigGenerationAndReusesExistingReload() throws {
        let tunnel = try readSource(.packetTunnelProvider)
        XCTAssertTrue(tunnel.contains("startFocusConfigurationPoll()"),
                      "The tunnel must start the Focus config poll on tunnel-up.")
        XCTAssertTrue(tunnel.contains("stopFocusConfigurationPoll()"),
                      "The tunnel must stop the Focus config poll on tunnel-down.")
        XCTAssertTrue(tunnel.contains("func reloadSnapshotIfConfigurationGenerationAdvanced()"),
                      "The poll tick must compare the on-disk generation and reload on an advance.")
        XCTAssertTrue(tunnel.contains("requestSnapshotReload(reason: \"focus-config-poll\", force: true)"),
                      "The poll must drive the EXISTING requestSnapshotReload(force:true), not a new reload path.")
        XCTAssertTrue(tunnel.contains("focusConfigurationPollInterval: TimeInterval = 60"),
                      "The poll interval should be ~60s (prompt closed-app switch, negligible cost).")
        // The deliberately-removed, unreliable tunnel-side Darwin observer must NOT be reintroduced.
        XCTAssertFalse(tunnel.contains("CFNotificationCenterAddObserver"),
                       "The tunnel must not re-add a Darwin observer (0/14 device probes — use the poll).")
        // P2 fix: the poll watermark is advanced only on a successful ADOPT (in the snapshot load), never on
        // mere observation — else a poll firing in the extension's config-leads-pointer window would skip
        // the retry. The poll tick must NOT self-assign the watermark.
        // Start the marker at `func ...` (NOT `private func ...`) so the body's own `private func ` prefix
        // doesn't make `endingBefore: "private func "` match at offset 0 and return an empty block.
        let pollBlock = try sourceBlock(
            in: tunnel,
            startingAt: "func reloadSnapshotIfConfigurationGenerationAdvanced() {",
            endingBefore: "private func "
        )
        XCTAssertFalse(pollBlock.isEmpty, "The poll-body extraction must not be empty (guards the assertions below).")

        // PST-7 defense-in-depth: this existing 60s poll must also pick up a mid-session diagnostics-clear
        // whose IPC message was dropped, so the clear is applied MID-SESSION and not only at the next tunnel
        // start. It MUST use `force: false` — force:true was the PST-1 bug (it re-wiped accumulated history on
        // every apply); force:false respects the durable applied-marker so a re-run over an already-satisfied
        // clear is a no-op. The call must sit BEFORE the config-generation guards so it fires every tick.
        XCTAssertTrue(pollBlock.contains("applyDiagnosticsControlIfNeeded(force: false)"),
                      "The poll tick must pick up a mid-session diagnostics-clear via applyDiagnosticsControlIfNeeded(force: false).")
        XCTAssertFalse(pollBlock.contains("applyDiagnosticsControlIfNeeded(force: true)"),
                       "The poll tick must NEVER force:true — that was the PST-1 re-wipe bug (force:false respects the durable marker).")
        let diagApplyIdx = try XCTUnwrap(pollBlock.range(of: "applyDiagnosticsControlIfNeeded(force: false)")?.lowerBound)
        let inFlightGuardIdx = try XCTUnwrap(pollBlock.range(of: "guard !snapshotReloadInFlight else { return }")?.lowerBound)
        XCTAssertLessThan(diagApplyIdx, inFlightGuardIdx,
                          "The diagnostics apply must run BEFORE the config-generation guards so it fires every tick regardless of a Focus switch.")

        XCTAssertFalse(pollBlock.contains("lastObservedConfigurationGeneration = "),
                       "The poll must NOT advance the watermark on observation (only the adopt point may).")
        // The watermark advances via one guarded helper, called at BOTH adopt points: a full snapshot decode
        // AND the resident-already-satisfies early return (else a config-only / equivalent-filter bump would
        // never advance it → a 60s reload+DNS-reset loop — Codex P2).
        XCTAssertTrue(tunnel.contains("self.lastObservedConfigurationGeneration = max(self.lastObservedConfigurationGeneration, adoptedGeneration)"),
                      "The watermark helper must advance to the adopted generation, guarded by the live reload token.")
        XCTAssertEqual(tunnel.components(separatedBy: "self.advanceFocusConfigurationWatermark(").count - 1, 2,
                       "The watermark must advance at BOTH adopt points (full decode + resident-satisfies early return).")

        // Round 5 (Codex): the poll must NOT seed the watermark from the on-disk generation at start — that
        // generation may reflect a closed-app switch not yet ADOPTED, and seeding from it would suppress the
        // retry forever. The watermark is left to the startup load's adopt point.
        XCTAssertFalse(tunnel.contains("lastObservedConfigurationGeneration = loadConfiguration()?.configurationGeneration ?? 0"),
                       "startFocusConfigurationPoll must NOT seed the watermark from an unadopted on-disk generation.")

        // Round 7 (Codex round 6): the poll must NOT permanently bound a non-adopting generation. A bound
        // suppressed same-generation pointer-flip retries — a pre-flip recompile that transiently failed would
        // record gen N, then the poll would skip N even after the extension flipped current.json for N,
        // stranding the tunnel fail-closed (the extension can't send a provider reload). The retry-until-adopt
        // contract (in-flight-gated) is what correctly picks up the flip, so there is NO non-adopting bound.
        XCTAssertFalse(tunnel.contains("lastNonAdoptingReloadGeneration"),
                       "The poll must NOT bound a non-adopting generation (it would suppress same-generation flip retries).")
        XCTAssertFalse(tunnel.contains("recordNonAdoptingReloadGeneration"),
                       "The non-adopting-generation bound must be fully removed.")

        // Round 5 (Codex): the poll must NOT re-request while the latest reload is still running — re-requesting
        // bumps the reload generation and invalidates the in-flight load (a >interval load would never adopt).
        XCTAssertTrue(pollBlock.contains("guard !snapshotReloadInFlight else { return }"),
                      "The poll must skip a tick while a snapshot reload is already in flight.")
        XCTAssertTrue(tunnel.contains("snapshotReloadInFlight = true"),
                      "The reload chokepoint (nextSnapshotReloadGeneration) must mark the load in flight.")
        XCTAssertTrue(tunnel.contains("defer { self.clearSnapshotReloadInFlight(ifCurrentGeneration: generation) }"),
                      "The detached load must clear the in-flight marker via defer on every exit path.")
        XCTAssertTrue(tunnel.contains("snapshotReloadInFlight = false"),
                      "The in-flight marker must be cleared (on load resolve + on invalidation, so the poll can't wedge).")
        // The clear must be generation-gated so an overlapping newer reload keeps ownership of the marker.
        XCTAssertTrue(tunnel.contains("func clearSnapshotReloadInFlight(ifCurrentGeneration generation: UInt64)"),
                      "The in-flight clear must exist and be generation-gated.")
    }

    /// Codex review (lavasec-ios#29): the foreground manual switch must treat an `.abortedSuperseded`
    /// artifact-publish (a concurrent cross-process Focus commit won the active-filter race, so the flip
    /// was degrade-aborted and the live pointer names the Focus target) as a DEFERRED, non-winning switch —
    /// not a false success. It must surface the PublishOutcome from persistSharedState and, on abort,
    /// dismiss the cover + return early (no foreground-switch stamp, no "Success" toast), letting the
    /// re-dispatched reconcile adopt the genuinely-newer on-disk selection.
    func testForegroundSwitchTreatsAbortedSupersededFlipAsDeferredNotSuccess() throws {
        let app = try readSource(.appViewModel)

        // persistSharedState must SURFACE the publish outcome (not discard it) so the caller can react.
        XCTAssertTrue(app.contains("@discardableResult\n    private func persistSharedState("),
                      "persistSharedState must be @discardableResult so the 13 non-switch callers stay byte-identical while switchToFilter can read the outcome.")
        XCTAssertTrue(app.contains(") async throws -> FilterSnapshotPreparationService.PublishOutcome {"),
                      "persistSharedState must return the PublishOutcome of the artifact flip.")
        XCTAssertTrue(app.contains("publishOutcome = try await persistPreparedSnapshotArtifacts("),
                      "The flip outcome must be captured, not discarded.")

        let block = try sourceBlock(
            in: app,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "private func prepareSwitchPublication("
        )
        XCTAssertTrue(block.contains("let publishOutcome = try await persistSharedState(preparedSnapshot: publication.preparedSnapshot)"),
                      "switchToFilter must capture persistSharedState's outcome.")
        XCTAssertTrue(block.contains("if case .abortedSuperseded = publishOutcome {"),
                      "switchToFilter must branch on an aborted (cross-process-superseded) flip.")

        // The abort branch must precede the success path (stamp + 'Success'), and early-return.
        let gateIdx = try XCTUnwrap(block.range(of: "guard configurationReplacementGate.isCurrent(switchToken) else {")?.lowerBound)
        let abortIdx = try XCTUnwrap(block.range(of: "if case .abortedSuperseded = publishOutcome {")?.lowerBound)
        let stampIdx = try XCTUnwrap(block.range(of: "PendingFilterSwitchStore.recordForegroundSwitch(at: switchInitiatedAt")?.lowerBound)
        let successToastIdx = try XCTUnwrap(block.range(of: "message: \"Success\"")?.lowerBound)
        XCTAssertLessThan(gateIdx, abortIdx,
                          "The in-process supersession gate guard must precede the cross-process abort dismiss, so a newer in-process cover-driving switch is never clobbered (Codex #29 follow-up).")
        XCTAssertLessThan(abortIdx, stampIdx, "The aborted-flip branch must come before the foreground-switch stamp.")
        XCTAssertLessThan(abortIdx, successToastIdx, "The aborted-flip branch must come before the Success toast.")
        let abortArm = try sourceBlock(in: block, startingAt: "if case .abortedSuperseded = publishOutcome {", endingBefore: "// Stamp the foreground switch time")
        XCTAssertTrue(abortArm.contains("return"),
                      "The aborted-flip branch must early-return (defer to the reconcile) rather than stamping success.")
        XCTAssertTrue(abortArm.contains("isFilterPreparationScreenPresented = false"),
                      "The aborted-flip branch must dismiss the preparation cover.")
    }

    /// A Focus-driven reconcile apply (`switchToFilter(stampsForegroundSwitch: false)`) must be SILENT —
    /// no full-screen preparation cover, no "Success" modal, no haptic — mirroring the committed-adopt
    /// path (`applyCommittedOnDiskActiveFilter`). Surfacing that modal for an automation the user did not
    /// initiate is what popped a "Success" page every time the app was opened after a Focus switch. Pin
    /// that every cover-driving UI mutation in the switch is gated on the stampsForegroundSwitch-derived
    /// flag, so a genuine user switch still shows the cover while the reconcile replay does not.
    func testProgrammaticFocusApplySuppressesPreparationCover() throws {
        let app = try readSource(.appViewModel)
        let block = try sourceBlock(
            in: app,
            startingAt: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {",
            endingBefore: "private enum SwitchPublication"
        )

        // The cover-suppression flag is DERIVED from stampsForegroundSwitch (only the reconcile passes
        // false), so a user switch keeps the cover and the automated replay drops it — no new call arg.
        XCTAssertTrue(block.contains("let presentsPreparationCover = stampsForegroundSwitch"),
                      "switchToFilter must derive presentsPreparationCover from stampsForegroundSwitch.")

        // A silent apply drives no cover, so it claims the replacement gate as a non-cover-driver.
        XCTAssertTrue(block.contains("configurationReplacementGate.begin(ownsPreparationCover: presentsPreparationCover)"),
                      "A silent Focus apply must claim the replacement gate as a non-cover-driver.")

        // Every cover / Success-state / haptic mutation must sit behind the flag — the initial cover
        // presentation, the deleted/frozen failure, the Success confirmation, and the catch-failure arm.
        XCTAssertGreaterThanOrEqual(
            block.components(separatedBy: "if presentsPreparationCover {").count - 1, 4,
            "The initial cover, the saving-progress churn, the Success block, and the failure arms must each be gated on presentsPreparationCover.")

        // The Success confirmation ("message: \"Success\"" + the success haptic) must be inside a gate.
        let successIdx = try XCTUnwrap(block.range(of: "message: \"Success\"")?.lowerBound)
        XCTAssertNotNil(block.range(of: "if presentsPreparationCover {", options: .backwards, range: block.startIndex..<successIdx),
                        "The Success cover + haptic must be gated by an if presentsPreparationCover block.")

        // The cold-compile progress is silenced too by threading the flag into prepareSwitchPublication.
        XCTAssertTrue(block.contains("presentsPreparationCover: presentsPreparationCover"),
                      "switchToFilter must pass presentsPreparationCover into prepareSwitchPublication.")

        let prepareBlock = try sourceBlock(
            in: app,
            startingAt: "private func prepareSwitchPublication(",
            endingBefore: "private func warmReusableSnapshotForSwitch("
        )
        XCTAssertTrue(prepareBlock.contains("presentsPreparationCover: Bool"),
                      "prepareSwitchPublication must accept the presentsPreparationCover flag.")
        XCTAssertTrue(prepareBlock.contains("if presentsPreparationCover {"),
                      "prepareSwitchPublication must gate its cold-compile progress churn on the flag.")

        // The reconcile is the caller that passes stampsForegroundSwitch:false (⇒ silent).
        let reconcileBlock = try sourceBlock(
            in: app,
            startingAt: "func reconcilePendingFilterSwitch() async {",
            endingBefore: "private func persistSharedState("
        )
        XCTAssertTrue(reconcileBlock.contains("await switchToFilter(id: request.targetFilterID, stampsForegroundSwitch: false)"),
                      "The reconcile replay must drive the silent (stampsForegroundSwitch:false) apply.")
    }

    // MARK: - Source introspection helpers
}
