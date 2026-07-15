import XCTest
@testable import LavaSecCore

/// Pins the INV-PERSIST-1 wiring that keeps a reboot-before-first-unlock launch from
/// wiping user state (the 2026-07-14 incident; lavasec-infra
/// `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`). The classifier and
/// the writer fence carry executable tests (`SharedStateFileReaderTests`,
/// `SharedFilterStatePersistenceTests`); these pins cover the app-side wiring the compiler
/// can't see: load-path classification, persist gating, first-unlock recovery, the
/// automatic-backup blast-radius guard, and the plan-Phase-4 field breadcrumbs.
final class RebootFirstUnlockGuardSourceTests: XCTestCase {
    // MARK: - Launch load classifies reads and gates the reseed persist

    func testLaunchLoadClassifiesReadsAndNeverPersistsAnUnreadableReseed() throws {
        let source = try readSource(.appViewModel)

        let loadBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadPersistedConfiguration() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        XCTAssertTrue(loadBlock.contains("SharedStateFileReader.read(AppConfiguration.self"),
                      "The config launch read must go through the INV-PERSIST-1 classifier.")
        XCTAssertTrue(loadBlock.contains("sharedStateUnavailableAtLoad = true"),
                      "An unreadable config read must mark the load blocked, not fall through to defaults-as-truth.")

        let migrateBlock = try sourceBlock(
            in: source,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func persistPreparedSnapshotArtifacts("
        )
        XCTAssertTrue(migrateBlock.contains("SharedStateFileReader.read(FilterLibrary.self"),
                      "The library launch read must go through the INV-PERSIST-1 classifier.")
        XCTAssertTrue(migrateBlock.contains("case .unreadable"),
                      "The library read must handle the unreadable outcome distinctly from absent/corrupt.")
        // The reseed may persist ONLY from a definitive (absent/corrupt) load. Pin the gate
        // and that it precedes the migration persist inside the foreground branch.
        let gateIdx = try XCTUnwrap(
            migrateBlock.range(of: "if !sharedStateUnavailableAtLoad {")?.lowerBound,
            "The migration persist must be gated on the load not having been blocked (INV-PERSIST-1)."
        )
        let persistIdx = try XCTUnwrap(
            migrateBlock.range(of: "try? persistConfigurationOnly(schedulesAutomaticBackup: false)")?.lowerBound
        )
        XCTAssertLessThan(gateIdx, persistIdx,
                          "The unavailable-at-load gate must guard the launch-time persist, not follow it.")
        // The durable stamp PRECEDES the persist (Codex P2 round 8): the shared writer lands
        // the library file first, so a crash/throw between its two writes must never leave a
        // durable seeded library without its marker. (Round 6's headless/poisoning hazard
        // stays closed by the foreground + absent/corrupt gating around this block.)
        let stampIdx = try XCTUnwrap(
            migrateBlock.range(of: "markLibraryOriginatesFromPersistedRecoveryReseed()")?.lowerBound,
            "The recovery reseed must stamp the durable marker for its persisted library."
        )
        XCTAssertLessThan(stampIdx, persistIdx,
                          "The durable stamp must precede the reseed persist — a mid-pair crash must not leave an unmarked seeded library.")
        // The persist is GATED on the stamp landing: a failed marker write must NOT persist a durable
        // seeded library with no durable marker, which the next launch reads .absentConfirmed and
        // clobbers (Codex P1 round 5 on #385). markerLanded is the stamp's confirmed-on-disk result
        // (true for the no-marker deliberate migration).
        XCTAssertTrue(
            migrateBlock.contains("? markLibraryOriginatesFromPersistedRecoveryReseed()"),
            "The stamp's confirmed-on-disk result must feed markerLanded."
        )
        let persistGateIdx = try XCTUnwrap(
            migrateBlock.range(of: "if markerLanded {")?.lowerBound,
            "The reseed persist must be gated on the marker landing (Codex P1 round 5 on #385)."
        )
        XCTAssertLessThan(stampIdx, persistGateIdx,
                          "The stamp must feed the markerLanded gate.")
        XCTAssertLessThan(persistGateIdx, persistIdx,
                          "The markerLanded gate must wrap the reseed persist.")
    }

    // MARK: - Persist funnels refuse placeholder state (the post-unlock clobber half)

    func testPersistFunnelsRefuseWhileLaunchLoadWasBlocked() throws {
        let source = try readSource(.appViewModel)

        // Assert the guard PRECEDES the pair write in each funnel, not merely that both tokens
        // appear: a reorder that ran the write before the guard — or a duplicate write outside
        // the guard's else — would satisfy a bare `contains` yet still persist placeholder
        // state, the exact bug this test is named for (OCR follow-up on the 1.2.4 sync). Brings
        // this pin to parity with the ordering discipline of the launch-load / writer-fence
        // pins elsewhere in this file.
        let sharedFunnel = try sourceBlock(
            in: source,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )
        let sharedGuardIdx = try XCTUnwrap(
            sharedFunnel.range(of: "guard !sharedStateUnavailableAtLoad else")?.lowerBound,
            "persistSharedState must refuse to write placeholder state (INV-PERSIST-1)."
        )
        let sharedWriteIdx = try XCTUnwrap(
            sharedFunnel.range(of: "writeSharedStateLoggingFenceTrip")?.lowerBound,
            "persistSharedState must route its pair write through the fence-logging wrapper."
        )
        XCTAssertLessThan(sharedGuardIdx, sharedWriteIdx,
                          "The unavailable-at-load guard must precede the pair write in persistSharedState.")

        let configFunnel = try sourceBlock(
            in: source,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func refreshFilterSwitchShortcutAfterPersist()"
        )
        let configGuardIdx = try XCTUnwrap(
            configFunnel.range(of: "guard !sharedStateUnavailableAtLoad else")?.lowerBound,
            "persistConfigurationOnly must refuse to write placeholder state (INV-PERSIST-1)."
        )
        let configWriteIdx = try XCTUnwrap(
            configFunnel.range(of: "writeSharedStateLoggingFenceTrip")?.lowerBound,
            "persistConfigurationOnly must route its pair write through the fence-logging wrapper."
        )
        XCTAssertLessThan(configGuardIdx, configWriteIdx,
                          "The unavailable-at-load guard must precede the pair write in persistConfigurationOnly.")
    }

    // MARK: - First-unlock recovery wiring

    func testBlockedLoadRecoversAtFirstUnlockAndOnForeground() throws {
        let source = try readSource(.appViewModel)

        XCTAssertTrue(source.contains("UIApplication.protectedDataDidBecomeAvailableNotification"),
                      "The app must re-run a blocked launch load when protected data becomes available.")

        let recovery = try sourceBlock(
            in: source,
            startingAt: "private func reloadSharedStateIfBlockedByDataProtection() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        XCTAssertTrue(recovery.contains("guard sharedStateUnavailableAtLoad else { return }"),
                      "The recovery reload must be a no-op on a normal (unblocked) launch.")
        XCTAssertTrue(recovery.contains("loadPersistedConfiguration()"),
                      "Recovery must re-run the full launch load against the now-readable files.")
        // The init task's launch tail ran against the placeholder (and a locked catalog
        // cache) and skipped the onboarded reconcile — recovery reruns catalog + reconcile
        // in init's order so derived rule state rebuilds before the snapshot reconcile
        // (Codex P1 round 5 + P2 round 7).
        XCTAssertTrue(recovery.contains("if loadsVPNState {"),
                      "Recovery must rerun the launch tail it ran against the placeholder pre-unlock.")
        let catalogLoadIdx = try XCTUnwrap(recovery.range(of: "await loadCachedCatalogIfAvailable()")?.lowerBound,
                                           "Recovery must reload the catalog cache against the real config.")
        let catalogSyncIdx = try XCTUnwrap(recovery.range(of: "await syncCatalogIfStale()")?.lowerBound)
        let reconcileIdx = try XCTUnwrap(recovery.range(of: "await reconcileTunnelSnapshotAfterLaunch()")?.lowerBound,
                                         "The rerun launch tail must reconcile the tunnel snapshot.")
        XCTAssertLessThan(catalogLoadIdx, catalogSyncIdx, "Catalog cache load precedes the staleness sync (init order).")
        XCTAssertLessThan(catalogSyncIdx, reconcileIdx, "The reconcile must build from real rules — catalog first (init order).")

        let foreground = try sourceBlock(
            in: source,
            startingAt: "func setAppForegroundActive(_ active: Bool) {",
            endingBefore: "func reconcilePendingFilterSwitch()"
        )
        XCTAssertTrue(foreground.contains("reloadSharedStateIfBlockedByDataProtection()"),
                      "Every foreground must re-check the blocked-load recovery (missed-notification catch).")
    }

    // MARK: - The Class-None library accept honors the durable file marker (scoped upgrade freeze)

    func testAcceptedLibraryHonorsDurableFileMarker() throws {
        let app = try readSource(.appViewModel)

        // INV-PERSIST-2 made filter-library.json Class-None, so the accept branch runs
        // pre-first-unlock. A 1.2.5-native device's suppression lives in the Class-None
        // ReseedSuppressionMarkerStore FILE (readable while locked), so the accept decides it
        // INLINE via a three-state read — no protected-data gate. The ONE case that cannot decide
        // inline is a device upgrading from 1.2.4 whose legacy Class-C marker has NOT migrated to
        // the file and whose first launch is pre-unlock: the accept must FREEZE the suppression
        // (never lift on the spurious locked `false`) and re-derive at unlock (Codex P1 on #385).
        let acceptBranch = try sourceBlock(
            in: app,
            startingAt: "if normalized.isValid,",
            endingBefore: "mirrorActiveFilterIntoConfiguration()"
        )
        XCTAssertTrue(
            acceptBranch.contains("switch reseedSuppressionMarkerState() {"),
            "The accept branch must re-derive the suppression from the three-state marker read."
        )
        // The upgrade-transition (.absentUnconfirmed) case freezes: keep suppression + arm re-derive.
        let unconfirmedIdx = try XCTUnwrap(
            acceptBranch.range(of: "case .absentUnconfirmed:")?.lowerBound,
            "The accept must handle the locked-legacy-store (upgrade-transition) case distinctly."
        )
        let freezeIdx = try XCTUnwrap(
            acceptBranch.range(of: "reseedSuppressionAwaitingUnlockConfirmation = true")?.lowerBound,
            "The .absentUnconfirmed case must arm the unlock re-derivation."
        )
        XCTAssertLessThan(unconfirmedIdx, freezeIdx,
                          "The freeze flag must be armed inside the .absentUnconfirmed case.")
        XCTAssertFalse(
            acceptBranch.contains("isProtectedDataAvailable"),
            "The accept branch itself must not gate on protected data — the state helper owns that read."
        )

        // The state helper: file-marker existence-probe (readable pre-unlock) first; a locked read
        // with no file marker returns .absentUnconfirmed BEFORE any Class-C legacy read (a locked
        // legacy read is a spurious `false`); the legacy fallback runs only while readable and is
        // migrated forward to the durable file.
        let helper = try sourceBlock(
            in: app,
            startingAt: "private func reseedSuppressionMarkerState() -> ReseedSuppressionMarkerState {",
            endingBefore: "private var reseedSuppressionAwaitingUnlockConfirmation"
        )
        XCTAssertTrue(
            helper.contains("ReseedSuppressionMarkerStore.isMarked(containerURL: containerURL)"),
            "The state helper must probe the durable Class-None marker file first."
        )
        let lockedGuardIdx = try XCTUnwrap(
            helper.range(of: "guard UIApplication.shared.isProtectedDataAvailable else")?.lowerBound,
            "A locked device with no file marker must not read the Class-C legacy store."
        )
        let unconfirmedReturnIdx = try XCTUnwrap(
            helper.range(of: "return .absentUnconfirmed")?.lowerBound,
            "A locked read with no file marker must return .absentUnconfirmed, not a lift."
        )
        let legacyReadIdx = try XCTUnwrap(
            helper.range(of: "UserDefaults.standard.bool(forKey: Self.recoveryReseedBackupSuppressionKeyName)")?.lowerBound,
            "The helper must consult the legacy Class-C marker when readable."
        )
        XCTAssertLessThan(lockedGuardIdx, unconfirmedReturnIdx,
                          "The locked guard must return .absentUnconfirmed before any legacy read.")
        XCTAssertLessThan(unconfirmedReturnIdx, legacyReadIdx,
                          "The legacy read must sit AFTER the locked guard (reached only while readable).")
        // The legacy Class-C key is CONSUMED in BOTH markers-present branches so a leftover never
        // resurrects (Codex P2 x2 on #385): the migrate-forward branch (mark the durable file FIRST,
        // then remove — kill-safe) AND the file-marker-already-present branch (a prior migration
        // killed between mark and remove left a stale key; the durable file is authoritative, so the
        // leftover is cleared on the next readable launch, never migrated back after a reset).
        XCTAssertEqual(
            sourceOccurrenceCount(of: "UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)", in: helper),
            2,
            "The legacy key must be consumed in BOTH the file-marker-present and the migrate-forward branches."
        )
        // The migrate-forward consume is GATED on mark() confirming the file marker on disk: a failed
        // app-group write must KEEP the legacy key for retry, never strand the accepted reseed with
        // no durable marker (Codex P1 on #385).
        XCTAssertTrue(
            helper.contains("if ReseedSuppressionMarkerStore.mark(containerURL: containerURL) {"),
            "The migrate-forward consume must be gated on mark() confirming the file marker on disk."
        )
        let migrateMarkIdx = try XCTUnwrap(
            helper.range(of: "if ReseedSuppressionMarkerStore.mark(containerURL: containerURL) {")?.lowerBound,
            "The readable-legacy branch must migrate the marker forward to the durable file."
        )
        XCTAssertLessThan(legacyReadIdx, migrateMarkIdx,
                          "The migrate-forward mark must follow the legacy read.")
        let migrateConsumeRange = helper.range(
            of: "UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)",
            range: migrateMarkIdx..<helper.endIndex
        )
        XCTAssertNotNil(migrateConsumeRange,
                        "The migrate-forward branch must CONSUME the legacy key AFTER a confirmed mark (kill-safe ordering).")

        // The frozen suppression is re-derived once protected data is readable — wired to BOTH the
        // first-unlock notification and the foreground re-check, because an accepted (readable)
        // library never sets sharedStateUnavailableAtLoad, so the blocked-load reload never covers it.
        XCTAssertEqual(sourceOccurrenceCount(of: "confirmReseedSuppressionAfterUnlock()", in: app), 3,
                       "The unlock re-derivation must be called from the unlock notification and the foreground re-check (plus its own definition).")
        let confirm = try sourceBlock(
            in: app,
            startingAt: "private func confirmReseedSuppressionAfterUnlock() {",
            endingBefore: "// Re-runs the blocked launch load at first unlock"
        )
        XCTAssertTrue(confirm.contains("guard reseedSuppressionAwaitingUnlockConfirmation else { return }"),
                      "The re-derivation is a no-op unless a pre-unlock accept armed the freeze.")
        XCTAssertTrue(confirm.contains("guard UIApplication.shared.isProtectedDataAvailable else { return }"),
                      "The re-derivation must only run once protected data is actually readable.")
        XCTAssertTrue(confirm.contains("reseedSuppressionAwaitingUnlockConfirmation = false"),
                      "The re-derivation must clear the freeze so it runs at most once.")
        XCTAssertTrue(confirm.contains("switch reseedSuppressionMarkerState()"),
                      "The re-derivation must set the suppression from the now-definitive marker state.")

        // The 1.2.4 whole-accept deferred-read hack (which deferred EVERY pre-unlock accept) stays
        // gone: the file marker decides a 1.2.5-native device inline. Only the scoped upgrade freeze
        // remains, under its new symbols.
        XCTAssertEqual(sourceOccurrenceCount(of: "reseedSuppressionMarkerDeferredUntilUnlock", in: app), 0,
                       "The 1.2.4 blanket deferred-marker flag must stay gone — replaced by the scoped freeze.")
        XCTAssertEqual(sourceOccurrenceCount(of: "reloadReseedSuppressionMarkerAfterUnlock", in: app), 0,
                       "The 1.2.4 blanket re-read method must stay gone — replaced by confirmReseedSuppressionAfterUnlock.")
    }

    // MARK: - Automatic backup cannot propagate a reseed (blast radius)

    func testAutomaticBackupIsSuppressedWhileLibraryOriginatesFromLaunchReseed() throws {
        let backup = try readSource(.backupController)
        let schedule = try sourceBlock(
            in: backup,
            startingAt: "func scheduleAutomaticBackupAfterConfigurationChange() {",
            endingBefore: "private func runScheduledAutomaticBackup()"
        )
        let guardIdx = try XCTUnwrap(
            schedule.range(of: "guard !hub.libraryOriginatesFromLaunchReseed else")?.lowerBound,
            "The automatic-backup scheduler must refuse while the library originated from a launch reseed."
        )
        let resealIdx = try XCTUnwrap(schedule.range(of: "refreshLocalEncryptedBackupEnvelope()")?.lowerBound)
        XCTAssertLessThan(guardIdx, resealIdx,
                          "The reseed guard must run BEFORE the local re-seal — the re-seal alone poisons the envelope a later manual upload sends.")

        // The suppression lifts exactly where the library becomes user-authoritative again —
        // the deliberate-migration reseed (1); a completed restore (TWO drop sites: the success
        // path and the post-pair-landed catch, Codex P2 round 5); and the explicit reseeds
        // (restore-to-default + onboarding), which BOTH route through
        // persistFilterReseedDroppingDurableMarkerWhenLanded and share ITS two drop sites (success
        // + post-pair-landed catch) so a failed reseed persist keeps the marker until the pair
        // lands (Codex P1 round 4). All go through the single clearing helper; the 6th match is
        // that helper's definition.
        let app = try readSource(.appViewModel)
        XCTAssertEqual(sourceOccurrenceCount(of: "clearLibraryOriginatesFromLaunchReseed()", in: app), 6,
                       "The suppression must clear at exactly the five deferred drop sites (deliberate-migration + restore ×2 + explicit-reseed helper ×2), via the marker-dropping helper (plus its definition).")
        // Persisted recovery reseeds (absent/corrupt store) mark the suppression DURABLY —
        // the reseed lands on disk as a valid library the next launch would otherwise
        // accept-and-lift (Codex P1). Exactly one call site plus the helper definition, and
        // the stamp must FOLLOW the successful persist: a headless read-only load or a
        // swallowed persist failure must never stamp a marker for a reseed that never
        // reached disk (Codex P2 round 6).
        XCTAssertEqual(sourceOccurrenceCount(of: "markLibraryOriginatesFromPersistedRecoveryReseed()", in: app), 2,
                       "Only the landed (persisted) recovery reseed may stamp the durable suppression marker.")
        // Durability now comes from the Class-None marker FILE, not a UserDefaults flush:
        // `synchronize()` is a no-op on modern iOS, so the old stamp/clear "crash barrier"
        // never existed (Kilo/OCR follow-up on the 1.2.4 sync). The stamp is an atomic
        // Class-None write (durable AND pre-unlock-readable, matching the library it guards)
        // and the clear is a durable file remove — both via ReseedSuppressionMarkerStore.
        XCTAssertEqual(sourceOccurrenceCount(of: "UserDefaults.standard.synchronize()", in: app), 0,
                       "The no-op UserDefaults flush must be gone — durability is the atomic Class-None marker file.")
        let markHelper = try sourceBlock(
            in: app,
            startingAt: "private func markLibraryOriginatesFromPersistedRecoveryReseed() -> Bool {",
            endingBefore: "private func clearLibraryOriginatesFromLaunchReseed() {"
        )
        XCTAssertTrue(markHelper.contains("ReseedSuppressionMarkerStore.mark(containerURL: containerURL)"),
                      "The stamp helper must write the durable Class-None marker file.")
        let clearHelper = try sourceBlock(
            in: app,
            startingAt: "private func clearLibraryOriginatesFromLaunchReseed() {",
            endingBefore: "private enum ReseedSuppressionMarkerState {"
        )
        // Clear removes the flaky legacy Class-C key BEFORE the durable Class-None file marker so an
        // interruption in between leaves the durable file marker present, and the next readable
        // launch's isMarked branch consumes the legacy key against it (Codex P2 on #385). The
        // best-effort legacy remove has an ACCEPTED RESIDUAL — an unflushed remove + kill after the
        // file clear can still leave the key and re-suppress next launch — irreducible with a
        // best-effort UserDefaults key and fail-safe (recoverable over-suppression, never clobber);
        // see the source comment in clearLibraryOriginatesFromLaunchReseed.
        let clearLegacyIdx = try XCTUnwrap(
            clearHelper.range(of: "UserDefaults.standard.removeObject(forKey: Self.recoveryReseedBackupSuppressionKeyName)")?.lowerBound,
            "The clear helper must also drop the legacy Class-C key."
        )
        let clearFileIdx = try XCTUnwrap(
            clearHelper.range(of: "ReseedSuppressionMarkerStore.clear(containerURL: containerURL)")?.lowerBound,
            "The clear helper must remove the durable Class-None marker file."
        )
        XCTAssertLessThan(clearLegacyIdx, clearFileIdx,
                          "The legacy Class-C key must be removed BEFORE the durable file marker (interruption-safe ordering).")

        let migrate = try sourceBlock(
            in: app,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func reconcileLoadedLibraryGenerationIfNeeded()"
        )
        // The accept branch re-derives the suppression from the durable marker instead of
        // unconditionally lifting it — a corrupt-store reseed persists as a valid library
        // that the NEXT launch accepts (Codex P1). The durable marker is the Class-None
        // ReseedSuppressionMarkerStore file, read via the three-state reseedSuppressionMarkerState().
        XCTAssertTrue(migrate.contains("switch reseedSuppressionMarkerState() {"),
                      "Accepting an on-disk library must honor the durable recovery-reseed marker across relaunches.")
        // The unreadable placeholder keeps its suppression IN-MEMORY only, so the recovery
        // reload's accept of the user's real file can lift it.
        XCTAssertTrue(migrate.contains("} else if sharedStateUnavailableAtLoad {"),
                      "The unreadable reseed must be distinguished from the persisted recovery reseed.")
        // A readable, invariant-valid library rejected only for schema/write-race reasons is
        // the DESIGNED migration — its reseed must not suppress automatic backup.
        XCTAssertTrue(migrate.contains("reseedReplacesDeliberatelyMigratedLibrary = normalized.isValid"),
                      "The deliberate-migration distinction must key on the rejected library still being invariant-valid.")
        XCTAssertTrue(migrate.contains("if reseedReplacesDeliberatelyMigratedLibrary {"),
                      "The reseed branch must gate the backup suppression on the deliberate-migration distinction.")
        // An absent library beside a readable, decoded config is the pre-library build's
        // legacy upgrade — also the designed migration, never suppression (Codex P2 round 7).
        XCTAssertTrue(
            migrate.contains("if loadedLibrary == nil, !libraryWasCorrupt, !sharedStateUnavailableAtLoad, configurationLoadedFromDisk {"),
            "The legacy pre-library upgrade (absent library + decoded config) must classify as the designed migration."
        )
        // The restore drops the durable marker only AFTER its persist lands: a failed
        // restore must leave the marker so a still-persisted reseed can't be accepted with
        // suppression lifted on the next launch (Codex P1 round 4).
        let restoreBlock = try sourceBlock(
            in: app,
            startingAt: "func applyRestoredBackupPayload(",
            endingBefore: "// MARK: - LavaSecurity+ hub bridge"
        )
        let restorePersistIdx = try XCTUnwrap(
            restoreBlock.range(of: "persistSharedState(prioritizesConfigurationDurability: true)")?.lowerBound
        )
        let restoreClearIdx = try XCTUnwrap(
            restoreBlock.range(of: "clearLibraryOriginatesFromLaunchReseed()")?.lowerBound,
            "The restore must drop the durable marker via the clearing helper."
        )
        XCTAssertLessThan(restorePersistIdx, restoreClearIdx,
                          "The durable-marker drop must follow the successful restore persist, never precede it.")
        XCTAssertTrue(restoreBlock.contains("libraryOriginatesFromLaunchReseed = suppressionBeforeRestore"),
                      "A failed restore persist must re-arm the in-memory suppression from its pre-restore value.")
        // persistSharedState can throw AFTER the pair landed (artifact-publish step). The
        // catch must key the marker on what's on disk — the in-memory generation advances
        // exactly at pair-write success — not on the throw (Codex P2 round 5).
        XCTAssertTrue(restoreBlock.contains("configuration.configurationGeneration > generationBeforeRestorePersist"),
                      "A post-pair persist failure must still lift the suppression (the restored pair IS on disk).")
        // Seven setters by design: the durable-marker helper (stamped only after a persisted
        // recovery reseed lands, Codex P1 + P2 round 6); the two in-memory reseed branches
        // (unreadable, and absent/corrupt); the three suppression-KEEP arms of the marker
        // re-derivation — the accept's `.present` and `.absentUnconfirmed` (upgrade-transition
        // freeze) cases, plus the unlock re-derivation's `.present` case (Codex P1 on #385); and
        // the durable-clear-FAILURE re-arm in clearLibraryOriginatesFromLaunchReseed, which keeps
        // the in-memory flag consistent with a stuck on-disk marker (OCR P1 on the 1.2.5 sync). The
        // ordinary lift arms use `= false`; the re-arm is the sole `= true` on a clear path and
        // only on a failed durable remove.
        XCTAssertEqual(sourceOccurrenceCount(of: "libraryOriginatesFromLaunchReseed = true", in: app), 7,
                       "Only the launch-reseed branches, the marker re-derivation's suppression-keep arms, and the durable-clear-failure re-arm may set the reseed-origin flag true.")
    }

    // MARK: - Explicit reseeds defer the durable-marker drop until the persist lands

    func testExplicitReseedDefersDurableMarkerDropUntilPersistLands() throws {
        let app = try readSource(.appViewModel)

        // Both explicit-reseed entry points (restore-to-default, onboarding recommended-defaults)
        // must LIFT the in-memory suppression before the persist — so the reseed's backup hook runs
        // unsuppressed (the user chose these defaults) — but route the DURABLE marker drop through
        // the deferred helper, never clear it inline before the write. A durable-marker clear before
        // a persist that can fail (I/O / ENOSPC / writer fence) would strand the un-replaced on-disk
        // reseed with no marker; the next launch reads it .absentConfirmed and automatic backup
        // clobbers the last good server copy (INV-PERSIST-2 marker consequence; mirrors
        // restoreFromBackup, Codex P1 round 4 on #376).
        let resetBlock = try sourceBlock(
            in: app,
            startingAt: "func restoreFiltersToDefault() {",
            endingBefore: "func switchToFilter(id: String, stampsForegroundSwitch: Bool = true) async {"
        )
        let onboardBlock = try sourceBlock(
            in: app,
            startingAt: "func applyOnboardingRecommendedDefaults(",
            endingBefore: "func applyOnboardingConnectionPreferences("
        )
        for (label, block) in [("restoreFiltersToDefault", resetBlock), ("applyOnboardingRecommendedDefaults", onboardBlock)] {
            let liftIdx = try XCTUnwrap(
                block.range(of: "libraryOriginatesFromLaunchReseed = false")?.lowerBound,
                "\(label) must lift the in-memory suppression so the reseed's backup hook runs unsuppressed."
            )
            let persistIdx = try XCTUnwrap(
                block.range(of: "persistFilterReseedDroppingDurableMarkerWhenLanded()")?.lowerBound,
                "\(label) must persist via the deferred-marker-drop helper, not a funnel that leaves the marker cleared."
            )
            XCTAssertLessThan(liftIdx, persistIdx,
                              "\(label): the in-memory lift must precede the deferred-marker persist.")
            XCTAssertFalse(block.contains("clearLibraryOriginatesFromLaunchReseed()"),
                           "\(label) must NOT drop the durable marker inline before the persist — the helper defers it until the pair lands.")
        }

        // The helper drops the durable marker only AFTER persistSharedState lands the pair: the
        // success path clears it post-persist, and the catch clears it ONLY when the generation
        // advanced past the pre-persist basis (the pair reached disk before a post-pair throw) —
        // never on a throw where nothing landed.
        let helper = try sourceBlock(
            in: app,
            startingAt: "private func persistFilterReseedDroppingDurableMarkerWhenLanded() {",
            endingBefore: "private func loadPersistedConfiguration"
        )
        let basisIdx = try XCTUnwrap(
            helper.range(of: "let generationBeforePersist = configuration.configurationGeneration")?.lowerBound,
            "The helper must capture the pre-persist generation basis."
        )
        let persistCallIdx = try XCTUnwrap(
            helper.range(of: "try await persistSharedState()")?.lowerBound
        )
        let successClearIdx = try XCTUnwrap(
            helper.range(of: "clearLibraryOriginatesFromLaunchReseed()")?.lowerBound,
            "The helper must drop the durable marker on the landed persist."
        )
        XCTAssertLessThan(basisIdx, persistCallIdx,
                          "The generation basis must be captured before the persist.")
        XCTAssertLessThan(persistCallIdx, successClearIdx,
                          "The durable-marker drop must FOLLOW the persist, never precede it.")
        XCTAssertTrue(
            helper.contains("configuration.configurationGeneration > generationBeforePersist"),
            "The catch must drop the marker only when the pair reached disk (generation advanced), not on any throw."
        )
    }

    // MARK: - Onboarding completion coalesces its persists so the deferred marker clear isn't raced

    func testOnboardingCompletionCoalescesToASingleMarkerClearingPersist() throws {
        // The onboarding reseed's deferred durable-marker clear (see the test above) is only safe if
        // NO sibling persist lands the seeded pair first. OnboardingFlowView.go(to: .done) applies
        // the leaving step's surfaced choice AND seeds the recommended defaults in the same
        // transition, so the leaving choice must be folded into the reseed's single persist —
        // otherwise its own fire-and-forget persist could land the seeded pair while the durable
        // marker is still present, and a kill before the deferred clear relaunches the onboarded
        // defaults as a suppressed reseed (Codex P2 on #386).
        let flow = try readSource(.onboardingFlowView)
        let goBlock = try sourceBlock(
            in: flow,
            startingAt: "private func go(to nextPage: OnboardingPage) {",
            endingBefore: "pageHistory.append(page)"
        )
        XCTAssertTrue(goBlock.contains("applyCurrentStepChoiceIfNeeded(persistImmediately: nextPage != .done)"),
                      "go(to: .done) must fold the leaving choice into the reseed persist, not fire its own.")
        XCTAssertTrue(goBlock.contains("if nextPage == .done {"),
                      "The .done transition must still seed the recommended defaults (the reseed persist the fold targets).")

        // Both surfaced-choice appliers MUTATE config unconditionally but gate their OWN persist on
        // the flag, so the .done fold suppresses the sibling persist while keeping the mutation.
        let app = try readSource(.appViewModel)
        let appliers = [
            ("func applyOnboardingConnectionPreferences(", "func selectOnboardingBlocklists("),
            ("func selectOnboardingBlocklists(", "private func startOnboardingDefaultBlocklistSyncIfNeeded()"),
        ]
        for (anchor, endBefore) in appliers {
            let block = try sourceBlock(in: app, startingAt: anchor, endingBefore: endBefore)
            XCTAssertTrue(block.contains("persistImmediately: Bool = true"),
                          "\(anchor) must take the persistImmediately flag (defaulting true).")
            let guardIdx = try XCTUnwrap(
                block.range(of: "if persistImmediately {")?.lowerBound,
                "\(anchor) must gate its persist on persistImmediately so the .done fold suppresses it."
            )
            let persistIdx = try XCTUnwrap(
                block.range(of: "persistFilterChanges()")?.lowerBound,
                "\(anchor) must still persist when not folded."
            )
            XCTAssertLessThan(guardIdx, persistIdx,
                              "\(anchor): the persist must be inside the persistImmediately guard.")
        }
    }

    // MARK: - The onboarding neutralize never fires on a locked defaults read

    func testOnboardingNeutralizeIsGatedOnProtectedDataAvailability() throws {
        let source = try readSource(.appViewModel)
        let initTask = try sourceBlock(
            in: source,
            startingAt: "if !hasCompletedOnboarding {",
            endingBefore: "await loadCachedCatalogIfAvailable()"
        )
        let gateIdx = try XCTUnwrap(
            initTask.range(of: "if UIApplication.shared.isProtectedDataAvailable {")?.lowerBound,
            "The launch neutralize must not trust a `hasCompletedOnboarding == false` read taken while UserDefaults is protection-locked."
        )
        let neutralizeIdx = try XCTUnwrap(
            initTask.range(of: "await neutralizeInheritedProtectionDuringOnboarding()")?.lowerBound
        )
        XCTAssertLessThan(gateIdx, neutralizeIdx,
                          "The protected-data gate must wrap the destructive neutralize (it stops + removes the VPN profile).")
    }

    // MARK: - Writer fence placement (the executable half lives in SharedFilterStatePersistenceTests)

    func testSharedWriterFencesUnreadableStateBeforeAnyWrite() throws {
        let writer = try readSource(.sharedFilterStatePersistence)
        let fenceIdx = try XCTUnwrap(
            writer.range(of: "SharedStateFileReader.fileExistsButIsUnreadable(at: configurationURL)")?.lowerBound,
            "The pair writer must classify existing-but-unreadable targets before writing (INV-PERSIST-1)."
        )
        XCTAssertTrue(writer.contains("SharedStateFileReader.fileExistsButIsUnreadable(at: filterLibraryURL)"),
                      "Both files of the pair must be fenced — either being unreadable aborts the write.")
        let bumpIdx = try XCTUnwrap(
            writer.range(of: "max(configuration.configurationGeneration, onDiskConfigurationGeneration(at: configurationURL)) + 1")?.lowerBound
        )
        XCTAssertLessThan(fenceIdx, bumpIdx,
                          "The unreadable fence must precede the generation bump — a blind bump is how defaults win.")
    }

    // MARK: - Field breadcrumbs: classifications and fence trips are diagnosable (plan Phase 4)

    func testUnreadableClassificationsAndFenceTripsLeaveFieldBreadcrumbs() throws {
        let app = try readSource(.appViewModel)

        // Each launch-load classification site logs a breadcrumb naming ITS file: the pair
        // carries NSFileProtectionNone post-INV-PERSIST-2, so which file classified
        // unreadable (config, library, or both) is the difference between a pre-migration
        // locked boot and a live anomaly. Anchor each event inside its `.unreadable` case.
        let loadBlock = try sourceBlock(
            in: app,
            startingAt: "private func loadPersistedConfiguration() {",
            endingBefore: "private func loadOrMigrateFilterLibrary()"
        )
        let configCaseIdx = try XCTUnwrap(loadBlock.range(of: "case .unreadable")?.lowerBound)
        let configEventIdx = try XCTUnwrap(
            loadBlock.range(of: "event: \"config-unreadable-at-load\"")?.lowerBound,
            "The config .unreadable classification must leave a per-file field breadcrumb."
        )
        XCTAssertLessThan(configCaseIdx, configEventIdx,
                          "The config breadcrumb must log from the .unreadable classification, not a definitive outcome.")
        // The outcome's `.unreadable(description:)` payload must ride into the breadcrumb so a
        // field log distinguishes a Data-Protection lock from a real I/O fault (SharedStateFile-
        // ReadOutcome documents the payload for exactly this — otherwise it is a dead value).
        XCTAssertTrue(loadBlock.contains("\"error\": description"),
                      "The config unreadable breadcrumb must carry the outcome's underlying read error.")

        let migrateBlock = try sourceBlock(
            in: app,
            startingAt: "private func loadOrMigrateFilterLibrary() {",
            endingBefore: "private func persistPreparedSnapshotArtifacts("
        )
        let libraryCaseIdx = try XCTUnwrap(migrateBlock.range(of: "case .unreadable")?.lowerBound)
        let libraryEventIdx = try XCTUnwrap(
            migrateBlock.range(of: "event: \"filter-library-unreadable-at-load\"")?.lowerBound,
            "The library .unreadable classification must leave a per-file field breadcrumb."
        )
        XCTAssertLessThan(libraryCaseIdx, libraryEventIdx,
                          "The library breadcrumb must log from the .unreadable classification, not a definitive outcome.")
        XCTAssertTrue(migrateBlock.contains("\"error\": description"),
                      "The library unreadable breadcrumb must carry the outcome's underlying read error.")

        // A writer-fence trip (`ExistingStateUnreadableError`) should be unreachable while
        // the funnels guard on `sharedStateUnavailableAtLoad` — so a hit is exactly the
        // field evidence the 2026-07-14 incident never left. The wrapper must log LOUDLY
        // and RETHROW: swallowing would turn an invariant violation into a silent no-op.
        let fenceWrapper = try sourceBlock(
            in: app,
            startingAt: "private func writeSharedStateLoggingFenceTrip(",
            endingBefore: "private func syncActiveFilterFromConfiguration()"
        )
        let catchIdx = try XCTUnwrap(
            fenceWrapper.range(of: "catch let error as SharedFilterStatePersistence.ExistingStateUnreadableError")?.lowerBound,
            "The wrapper must catch exactly the writer's unreadable fence, not all errors."
        )
        let fenceEventIdx = try XCTUnwrap(
            fenceWrapper.range(of: "event: \"persist-blocked-existing-unreadable\"")?.lowerBound,
            "A fence trip must leave the loud should-be-unreachable breadcrumb."
        )
        let rethrowIdx = try XCTUnwrap(
            fenceWrapper.range(of: "throw error")?.lowerBound,
            "The wrapper must rethrow — the caller's error path still applies."
        )
        XCTAssertLessThan(catchIdx, fenceEventIdx)
        XCTAssertLessThan(fenceEventIdx, rethrowIdx,
                          "The breadcrumb must land before the rethrow so a crashing caller still leaves the trace.")

        // Both foreground funnels — and nothing else — route their shared-writer call
        // through the wrapper (the writer-invariant pins keep the funnels themselves the
        // only two delegates, so together every app-side pair write logs fence trips).
        let sharedFunnel = try sourceBlock(
            in: app,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )
        XCTAssertTrue(sharedFunnel.contains("try writeSharedStateLoggingFenceTrip {"),
                      "persistSharedState must route its pair write through the fence-logging wrapper.")
        let configFunnel = try sourceBlock(
            in: app,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func refreshFilterSwitchShortcutAfterPersist()"
        )
        XCTAssertTrue(configFunnel.contains("try writeSharedStateLoggingFenceTrip {"),
                      "persistConfigurationOnly must route its pair write through the fence-logging wrapper.")
        XCTAssertEqual(sourceOccurrenceCount(of: "try writeSharedStateLoggingFenceTrip {", in: app), 2,
                       "Exactly the two persist funnels use the wrapper — a third caller would be a new write path to scrutinize.")
    }

    func testLanguagePinPublishIsGuardedOnProtectedData() throws {
        let app = try readSource(.appViewModel)
        let foreground = try sourceBlock(
            in: app,
            startingAt: "func setAppForegroundActive(_ active: Bool) {",
            endingBefore: "func reconcilePendingFilterSwitch()"
        )
        // A pre-first-unlock foreground (prewarm / notification launch) resolves this
        // process's bundle against a still-locked AppleLanguages state; publishing that
        // would overwrite the user's language pin (zh-Hant -> en) in the shared suite —
        // the notification/Live Activity half of the incident's language flip (plan
        // Phase 3). The publish must sit inside the protected-data guard; the next
        // post-unlock foreground republishes the correct resolution.
        XCTAssertTrue(
            foreground.contains("""
            if UIApplication.shared.isProtectedDataAvailable {
                LavaNotificationLanguage.publish(LavaNotificationLanguage.currentAppLocalization(), to: defaults)
            }
"""),
            "The language-pin publish must be guarded on isProtectedDataAvailable."
        )
        XCTAssertEqual(
            sourceOccurrenceCount(of: "LavaNotificationLanguage.publish(", in: app), 1,
            "The guarded foreground publish must remain the ONLY pin publish site."
        )
    }

    func testForegroundActivePublishIsGuardedOnProtectedData() throws {
        let app = try readSource(.appViewModel)
        let foreground = try sourceBlock(
            in: app,
            startingAt: "func setAppForegroundActive(_ active: Bool) {",
            endingBefore: "func reconcilePendingFilterSwitch()"
        )
        // The foreground-active flag lives in the Class-C shared-defaults SUITE, unwritable
        // while the device is locked (INV-PERSIST-2). A pre-first-unlock prewarm/notification
        // foreground must not attempt to persist it: the single publish site is gated on
        // protected-data availability, matching the language pin above. Anchor a TIGHT region —
        // the defaults binding up to the language-pin `if active {` — so the ordering assertion
        // sees only the foreground publish and its own gate, not the neighboring recovery/
        // migration/language gates in the same method.
        let publishRegion = try sourceBlock(
            in: foreground,
            startingAt: "let defaults = LavaSecAppGroup.sharedDefaults",
            endingBefore: "if active {"
        )
        let gateIdx = try XCTUnwrap(
            publishRegion.range(of: "if UIApplication.shared.isProtectedDataAvailable {")?.lowerBound,
            "The foreground-active publish must be gated on protected-data availability."
        )
        let publishIdx = try XCTUnwrap(
            publishRegion.range(of: "LavaAppForegroundPublication.publish(active, to: defaults)")?.lowerBound,
            "The foreground region must publish the active flag."
        )
        XCTAssertLessThan(gateIdx, publishIdx,
                          "The protected-data gate must precede the foreground-active publish.")
        XCTAssertEqual(
            sourceOccurrenceCount(of: "LavaAppForegroundPublication.publish(", in: app), 1,
            "The guarded publish must remain the ONLY foreground-flag publish site in the app model."
        )
    }
}
