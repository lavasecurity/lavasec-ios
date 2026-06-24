import XCTest

/// Source-introspection guard for the daily background catalog refresh (BGTask, LAV-90
/// Phase 2). The refresh runs on a headless `AppViewModel` that shares the App Group
/// container with the foreground app, so the publish must be **artifacts-only** and
/// **degrade-ABORT**: it re-reads the live on-disk configuration, builds from it, and
/// flips the pointer ONLY if (a) it can take the publish lock without contending a
/// foreground writer and (b) the on-disk configuration generation still matches the one
/// it built against. It never rewrites `configuration.json` and never restores protection
/// (both write shared state from the headless model and could clobber a foreground edit).
/// These invariants are awkward to exercise behaviorally (a live App Group container +
/// concurrent cross-process write), so they are locked in here.
final class BackgroundCatalogRefreshSourceTests: XCTestCase {
    func testBGTaskRunsSyncInBackgroundRefreshModeAndRegistersGatedScheduling() throws {
        let app = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")

        XCTAssertTrue(
            app.contains("await viewModel.syncCatalog(isBackgroundRefresh: true)"),
            "The BGTask must run the catalog sync in background mode."
        )
        XCTAssertTrue(
            app.contains("BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier")
                && app.contains("BackgroundCatalogRefresh.registerHandler()"),
            "The BGTask handler must be registered before launch finishes."
        )
        // Scheduling is OFF by default until the on-device pointer-swap gate passes:
        // scheduleNext must early-return unless the app-group opt-in flag is set.
        let scheduleBlock = try Self.block(in: app, from: "static func scheduleNext() {", to: "static func handle(")
        XCTAssertTrue(
            scheduleBlock.contains("guard LavaSecAppGroup.sharedDefaults.bool(forKey: optInDefaultsKey)"),
            "Background scheduling must be gated behind the off-by-default opt-in flag."
        )
        // Exactly-once completion + cancellation-on-expiration discipline preserved.
        XCTAssertTrue(app.contains("task.expirationHandler ="), "Must arm an expiration handler.")
        XCTAssertTrue(app.contains("work.cancel()"), "Expiration must cancel the in-flight sync.")
    }

    func testInfoPlistDeclaresProcessingModeAndTaskIdentifier() throws {
        let plist = try Self.source(named: "Info.plist", in: "LavaSecApp")
        XCTAssertTrue(plist.contains("<key>BGTaskSchedulerPermittedIdentifiers</key>"))
        XCTAssertTrue(plist.contains("<string>com.lavasec.catalog-refresh</string>"))
        XCTAssertTrue(plist.contains("<key>UIBackgroundModes</key>") && plist.contains("<string>processing</string>"))
    }

    func testSyncThreadsBackgroundFlagAndFreezesCustomListsInBackground() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        XCTAssertTrue(
            viewModel.contains("func syncCatalog(isBackgroundRefresh: Bool = false) async"),
            "syncCatalog must accept an isBackgroundRefresh flag."
        )
        XCTAssertTrue(
            viewModel.contains("func performCatalogSync(operationID: LatencyOperationID = .make(), isBackgroundRefresh: Bool = false) async"),
            "performCatalogSync must thread the isBackgroundRefresh flag."
        )
        // Background refresh must not network-refresh custom blocklists (would rotate
        // hashes it can't persist into the un-rewritten configuration.json).
        XCTAssertTrue(
            viewModel.contains("configuration.limits.allowsCustomBlocklists && !isBackgroundRefresh"),
            "Background refresh must keep custom lists strictly cache-only."
        )
        // The background branch hands off to the artifacts-only helper then finishes and
        // returns WITHOUT falling into the foreground persist path.
        let branch = try Self.block(in: viewModel, from: "if isBackgroundRefresh {", to: "// Smart refresh:")
        XCTAssertTrue(branch.contains("publishBackgroundRefreshArtifacts(operationID: operationID"))
        XCTAssertTrue(branch.contains("finishCatalogSyncTask()") && branch.contains("return"))
        XCTAssertFalse(
            branch.contains("persistSharedState("),
            "Background branch must not rewrite configuration.json via persistSharedState()."
        )
    }

    func testBGTaskUsesHeadlessViewModelThatGatesSideEffectingInit() throws {
        let app = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")
        XCTAssertTrue(
            app.contains("AppViewModel(loadVPNState: false, headless: true)"),
            "The BGTask must construct a HEADLESS AppViewModel so init installs no shared-state-writing side effects."
        )

        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        XCTAssertTrue(
            viewModel.contains("init(loadVPNState: Bool = true, headless: Bool = false)"),
            "init must accept a headless flag (default false)."
        )
        // The Plus-store entitlement listener (→ persistConfigurationOnly) and the
        // temporary-protection resume (→ resume protection) both write shared state from
        // the stale launch-time config, so both must be gated off behind `!headless`.
        let initBlock = try Self.block(
            in: viewModel,
            from: "init(loadVPNState: Bool = true, headless: Bool = false) {",
            to: "if loadVPNState {"
        )
        // Every side-effecting setup call must follow the !headless gate. This includes
        // the two that are not obviously writes: loadCustomizationPreferences (persists the
        // Guard look / app icon to app-group defaults) and loadTemporaryProtectionPause
        // (pauseController.onPauseCleared removes the app-group pause keys).
        let gateIdx = try XCTUnwrap(initBlock.range(of: "if !headless {")?.lowerBound,
                                    "Headless init must gate its side-effecting setup.")
        for call in [
            "startLavaSecurityPlusStore()",
            "loadCustomizationPreferences()",
            "loadTemporaryProtectionPause()",
            "scheduleTemporaryProtectionResume()",
        ] {
            let idx = try XCTUnwrap(initBlock.range(of: call)?.lowerBound, "missing init call: \(call)")
            XCTAssertLessThan(gateIdx, idx, "\(call) must sit behind the !headless gate.")
        }
    }

    func testBGTaskHandlerRereadsOptInBeforeRunningWork() throws {
        let app = try Self.source(named: "LavaSecApp.swift", in: "LavaSecApp")
        let handle = try Self.block(in: app, from: "private static func handle(", to: "task.expirationHandler =")
        // iOS can still deliver a BGProcessingTaskRequest that was pending when the opt-in
        // flipped OFF. The work task must re-read the flag and complete without constructing
        // or running the headless model — the flag is the off-switch for the unproven
        // background publisher.
        let guardIdx = try XCTUnwrap(
            handle.range(of: "guard LavaSecAppGroup.sharedDefaults.bool(forKey: optInDefaultsKey) else {")?.lowerBound,
            "handle() must re-read the opt-in flag inside the work task."
        )
        let modelIdx = try XCTUnwrap(handle.range(of: "AppViewModel(loadVPNState: false, headless: true)")?.lowerBound)
        XCTAssertLessThan(guardIdx, modelIdx, "The opt-in re-check must precede constructing/running the headless model.")
    }

    func testBackgroundPublishStopsWhenBGTaskHasExpired() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // (1) A cancellation guard must precede entering the background publish, so an
        // expired BGTask does not stage/flip artifacts past the system deadline.
        let branch = try Self.block(in: viewModel, from: "if isBackgroundRefresh {", to: "// Smart refresh:")
        let cancelIdx = try XCTUnwrap(branch.range(of: "guard !Task.isCancelled else {")?.lowerBound,
                                      "Background branch must guard cancellation before publishing.")
        let publishIdx = try XCTUnwrap(branch.range(of: "publishBackgroundRefreshArtifacts(operationID: operationID")?.lowerBound)
        XCTAssertLessThan(cancelIdx, publishIdx, "Cancellation guard must precede the background publish call.")

        // (2) The in-lock supersession closure (checked immediately before the pointer flip)
        // must also abort on expiration, so a task expiring mid-publish never flips.
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )
        XCTAssertTrue(
            helper.contains("if Task.isCancelled { return true }"),
            "The in-lock pre-flip check must abort the pointer flip if the BGTask expired."
        )
    }

    func testBackgroundFlipAbortsIfLivePointerMovedSinceBasis() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // The base pointer must be captured BEFORE the sync (so a concurrent foreground
        // publish during the sync is observed as a move) and only for the background path.
        let perform = try Self.block(in: viewModel, from: "private func performCatalogSync(operationID:", to: "private func publishBackgroundRefreshArtifacts(operationID:")
        XCTAssertTrue(
            perform.contains("let basePublishedPointerToken = isBackgroundRefresh ? currentPublishedArtifactPointerToken() : nil"),
            "Background must capture the published pointer token before syncing."
        )
        let baseIdx = try XCTUnwrap(perform.range(of: "let basePublishedPointerToken =")?.lowerBound)
        let syncIdx = try XCTUnwrap(perform.range(of: "Task.detached(priority: .utility)")?.lowerBound)
        XCTAssertLessThan(baseIdx, syncIdx, "Base pointer token must be captured before the detached sync.")

        // The in-lock supersession closure must abort the flip when the live pointer no
        // longer matches that captured basis (catalog-rollback guard).
        let helper = try Self.block(in: viewModel, from: "private func publishBackgroundRefreshArtifacts(operationID:", to: "private func didSnapshotIdentityChangeAfterSync()")
        XCTAssertTrue(
            helper.contains("if currentPointerToken != basePublishedPointerToken { return true }"),
            "The background flip must abort if a concurrent publish moved the live pointer."
        )
    }

    func testBackgroundPublishAbortsOnCustomFingerprintSkew() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )
        // Custom lists are cache-only; if a foreground refresh changed a fingerprint while we
        // synced, the cached bytes no longer match the reloaded identity → abort (the
        // generation token can't catch this, and the coverage guard only checks presence).
        XCTAssertTrue(helper.contains("enabledCustomBlocklistIdentities(in: configuration)"))
        XCTAssertTrue(helper.contains("\"bg-custom-changed\""))
        // The baseline must be captured BEFORE the config reload; the abort check after it.
        let baselineIdx = try XCTUnwrap(helper.range(of: "let baselineCustomIdentities = enabledCustomBlocklistIdentities(in: configuration)")?.lowerBound)
        let reloadIdx = try XCTUnwrap(helper.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let guardIdx = try XCTUnwrap(helper.range(of: "== baselineCustomIdentities else {")?.lowerBound)
        XCTAssertLessThan(baselineIdx, reloadIdx, "Baseline custom fingerprints must be captured before reloading config.")
        XCTAssertLessThan(reloadIdx, guardIdx, "The custom-fingerprint abort must come after the config reload.")
    }

    func testPublishServiceSkipsStagingWhenAlreadyCancelled() throws {
        let service = try Self.source(named: "FilterSnapshotPreparationService.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(service.contains("case abortedCancelled"), "Service must expose a distinct cancelled outcome.")
        // The pre-staging guard must precede stageVersionedArtifacts (so an expired BGTask
        // does not encode/write the versioned dir past the deadline) and apply only to
        // tryOrAbort (the blocking foreground path is never deadline-bound).
        let guardIdx = try XCTUnwrap(service.range(of: "if lockMode == .tryOrAbort, Task.isCancelled {")?.lowerBound,
                                     "Service must check cancellation before staging for tryOrAbort callers.")
        let stageIdx = try XCTUnwrap(service.range(of: "stageVersionedArtifacts(")?.lowerBound)
        XCTAssertLessThan(guardIdx, stageIdx, "Cancellation must be checked before staging encodes/writes the versioned dir.")
    }

    func testBackgroundRefreshFailurePathBailsBeforeWritingSharedState() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let perform = try Self.block(
            in: viewModel,
            from: "private func performCatalogSync(operationID:",
            to: "private func publishBackgroundRefreshArtifacts(operationID:"
        )
        // On a NON-cancellation sync error the foreground recovery restores from cache
        // (loadCachedCatalogAfterSyncFailure → persistSharedState) and then the tail arms
        // restoreProtectionIfNeeded — both write shared state from this headless model's
        // launch-time config. The background path must bail (a unique status terminal)
        // BEFORE either, exactly like the cancellation guard, so it never clobbers a
        // concurrent foreground edit on a failed refresh.
        let bgFailIdx = try XCTUnwrap(perform.range(of: "\"bg-sync-failed\"")?.lowerBound,
                                      "Failure path must tag a distinct bg terminal so it can be located.")
        let cacheRestoreIdx = try XCTUnwrap(perform.range(of: "loadCachedCatalogAfterSyncFailure(")?.lowerBound)
        XCTAssertLessThan(
            bgFailIdx, cacheRestoreIdx,
            "Background refresh must bail before loadCachedCatalogAfterSyncFailure (which calls persistSharedState)."
        )
    }

    func testBackgroundPublishHelperIsArtifactsOnlyDegradeAbortAndSupersessionGuarded() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )

        // Hybrid: re-read live config, coverage-guard, then publish artifacts-only.
        XCTAssertTrue(helper.contains("loadPersistedConfiguration()"))
        XCTAssertTrue(helper.contains("coversEnabledBlocklists(in: configuration)"))
        XCTAssertTrue(helper.contains("persistPreparedSnapshotArtifacts(") && helper.contains("notifyTunnelSnapshotUpdated("))
        // Degrade-ABORT publish lock + in-lock generation supersession check.
        XCTAssertTrue(helper.contains("lockMode: .tryOrAbort"))
        XCTAssertTrue(helper.contains("supersededWhileLocked:"))
        XCTAssertTrue(helper.contains("onDisk.configurationGeneration != builtGeneration"))
        // Never rewrites config or arms protection restore.
        XCTAssertFalse(
            helper.contains("persistSharedState("),
            "Background publish must not call persistSharedState()."
        )
        XCTAssertFalse(
            helper.contains("shouldAttemptProtectionRestore = true"),
            "Background publish must not arm protection restore."
        )
    }

    func testPublishServiceSupportsDegradeAbortAndSupersession() throws {
        let service = try Self.source(named: "FilterSnapshotPreparationService.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(service.contains("enum PublishLockMode"))
        XCTAssertTrue(service.contains("case tryOrAbort"))
        // The supersession check receives the live pointer token so a degrade-abort caller
        // can detect a concurrent publish (the catalog-rollback guard).
        XCTAssertTrue(service.contains("supersededWhileLocked: (@Sendable (_ currentPointerToken: String?) -> Bool)?"))
        XCTAssertTrue(
            service.contains("FilterPublishLock.withTryExclusiveLock(at: publishLockURL, flipUnderLock) ?? .abortedContended"),
            "tryOrAbort must use the non-blocking lock and abort (never degrade-open)."
        )
        // The live pointer must be read BEFORE the supersession check so the check can use it.
        let prevIdx = try XCTUnwrap(service.range(of: "let previousToken = artifactStore.loadArtifactPointer()?.token")?.lowerBound)
        let checkIdx = try XCTUnwrap(service.range(of: "supersededWhileLocked(previousToken)")?.lowerBound)
        XCTAssertLessThan(prevIdx, checkIdx, "previousToken must be read before being passed to supersededWhileLocked.")
    }

    func testConfigurationGenerationStampExistsAndForegroundWritersBumpIt() throws {
        let config = try Self.source(named: "AppConfiguration.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(config.contains("public var configurationGeneration: Int"))

        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // Both foreground writers advance the token via the monotonic helper (never a raw
        // +=1), so it cannot reset/collide across a backup restore that replaces the
        // in-memory configuration with a default-0 token.
        let sharedBlock = try Self.block(in: viewModel, from: "private func persistSharedState(", to: "private func advanceConfigurationGeneration(")
        XCTAssertTrue(sharedBlock.contains("advanceConfigurationGeneration()"),
                      "persistSharedState must advance the supersession token.")
        let configOnlyBlock = try Self.block(in: viewModel, from: "private func persistConfigurationOnly(", to: "private func uploadEncryptedBackup(")
        XCTAssertTrue(configOnlyBlock.contains("advanceConfigurationGeneration()"),
                      "persistConfigurationOnly must advance the supersession token.")
        // The helper derives the next token from the live ON-DISK value, so it stays
        // monotonic across a restore that resets the in-memory configuration to 0.
        XCTAssertTrue(viewModel.contains("max(configuration.configurationGeneration, onDiskConfigurationGeneration()) &+ 1"))
        XCTAssertTrue(viewModel.contains("private func onDiskConfigurationGeneration()"))
        // The old raw bump must be gone (it reset to 1 after a restore).
        XCTAssertFalse(viewModel.contains("configuration.configurationGeneration &+= 1"),
                       "Raw token increments reset after a restore — use the monotonic helper.")
    }

    func testBackgroundPublishBuildsSnapshotOffMainActorFromReloadedConfig() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )
        // The heavy merge + filterSnapshot must run OFF the main actor (detached task) so a
        // BGTask expiration handler (queued on .main) can preempt before the deadline.
        XCTAssertTrue(helper.contains("Task.detached(priority: .utility)"),
                      "Background snapshot build must run on a detached (off-main) task.")
        XCTAssertTrue(helper.contains("Self.buildBackgroundPreparedSnapshot("),
                      "Background path must build via the off-main static builder.")
        // It must NOT call the @MainActor foreground prep (that would re-block the main actor).
        XCTAssertFalse(helper.contains("preparedSnapshotForCurrentConfiguration()"),
                       "Background path must not call the @MainActor foreground prep.")
        // Smart-refresh no-op gate: an unchanged daily run must not churn a dir / reload.
        XCTAssertTrue(helper.contains("didSnapshotIdentityChangeAfterSync()"))
        // The build must be keyed on the RELOADED config (captured after loadPersistedConfiguration),
        // or it could over-block a list the foreground just disabled.
        let reloadIdx = try XCTUnwrap(helper.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let captureIdx = try XCTUnwrap(helper.range(of: "let configurationForBuild = configuration")?.lowerBound)
        let buildIdx = try XCTUnwrap(helper.range(of: "Self.buildBackgroundPreparedSnapshot(")?.lowerBound)
        XCTAssertTrue(reloadIdx < captureIdx && captureIdx < buildIdx,
                      "Must re-read config, capture it, then build the snapshot off-main.")

        // The builder is a nonisolated static (runs off the main actor) and merges from the
        // cached rule sets exactly once.
        let builder = try Self.block(
            in: viewModel,
            from: "nonisolated static func buildBackgroundPreparedSnapshot(",
            to: "private struct ProtectionStartupSnapshot"
        )
        XCTAssertTrue(builder.contains("mergedBlockRules(") && builder.contains("cachedBlockRuleSets"),
                      "Builder must merge the reloaded enabled set from the cached rule sets.")
        XCTAssertEqual(builder.components(separatedBy: "FilterSnapshotPreparationService.mergedBlockRules").count - 1, 1,
                       "Builder must merge exactly once (no redundant double-merge).")
    }

    func testBackgroundDefersCatalogCommitAndPublishesItAtomically() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        // The background sync defers the latest.json commit (foreground commits inline), so the
        // shared catalog can't run ahead of the pointer on an abort.
        XCTAssertTrue(
            viewModel.contains("commitsLatestCatalog: !isBackgroundRefresh"),
            "Background sync must defer the latest.json commit; foreground commits inline."
        )
        // It captures the pre-sync baseline only for the background path (CAS basis).
        XCTAssertTrue(viewModel.contains("baseLatestCatalogData: Data? = isBackgroundRefresh"))

        // The background publish commits latest.json via commitBeforeFlip — atomic with the flip,
        // gated by a CAS against the pre-sync baseline — and surfaces a veto terminal.
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )
        XCTAssertTrue(helper.contains("commitBeforeFlip:"), "Background publish must pass a commitBeforeFlip.")
        XCTAssertTrue(helper.contains("BlocklistCatalogRepository.latestCatalogURL(in: catalogCacheURL)"))
        XCTAssertTrue(helper.contains("latestCatalogData.write(to: latestCatalogURL"),
                      "Must write latest.json inside the commit hook.")
        XCTAssertTrue(helper.contains("onDiskLatestCatalog == baseLatestCatalogData"),
                      "Must CAS latest.json against the baseline before committing.")
        XCTAssertTrue(helper.contains("\"bg-catalog-superseded\""),
                      "A vetoed catalog commit must surface its own terminal (not a silent error).")
        // The commit must be gated on a successful publish: it must not write latest.json on the
        // bg-uncovered / bg-custom-changed / bg-unchanged early returns (those precede it).
        let commitIdx = try XCTUnwrap(helper.range(of: "latestCatalogData.write(to: latestCatalogURL")?.lowerBound)
        for earlyReturn in ["\"bg-custom-changed\"", "\"bg-uncovered\"", "\"bg-unchanged\""] {
            let idx = try XCTUnwrap(helper.range(of: earlyReturn)?.lowerBound)
            XCTAssertLessThan(idx, commitIdx, "\(earlyReturn) abort must precede (and skip) the latest.json commit.")
        }

        // sync() gates BOTH latest.json writes behind commitsLatestCatalog.
        let sync = try Self.source(named: "BlocklistCatalogSync.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(sync.contains("commitsLatestCatalog: Bool = true"))
        XCTAssertTrue(sync.contains("if commitsLatestCatalog, loadedCatalog.shouldCache"))
        XCTAssertTrue(sync.contains("if commitsLatestCatalog, !loadedCatalog.shouldCache"))
    }

    func testBackgroundPublishAbortsWhenForegroundMigrationHasNotLanded() throws {
        // Regression (#118 follow-up): an upgraded install whose on-disk library is still
        // pre-three-defaults (old schema) reseeds to Balanced on load and mirrors that into the
        // in-memory config WITHOUT persisting it in the headless path. The background publish must
        // detect that reseed and abort, or it would flip published artifacts to Balanced while
        // app-configuration.json (and its generation) still describe the pre-upgrade filter — a
        // silent flip the generation guard cannot catch (no config was written).
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")

        // loadOrMigrateFilterLibrary records whether it accepted the on-disk library or reseeded.
        let load = try Self.block(
            in: viewModel,
            from: "private func loadOrMigrateFilterLibrary()",
            to: "private func reconcileLoadedLibraryGenerationIfNeeded()"
        )
        XCTAssertTrue(load.contains("didReseedFilterLibraryOnLastLoad = false"),
                      "Accepting the on-disk library must clear the reseed flag.")
        XCTAssertTrue(load.contains("didReseedFilterLibraryOnLastLoad = true"),
                      "Reseeding the defaults must set the reseed flag.")
        // The flag is set in the reseed branch (after the accept-branch early return).
        let acceptReturnIdx = try XCTUnwrap(load.range(of: "didReseedFilterLibraryOnLastLoad = false")?.lowerBound)
        let reseedIdx = try XCTUnwrap(load.range(of: "didReseedFilterLibraryOnLastLoad = true")?.lowerBound)
        XCTAssertLessThan(acceptReturnIdx, reseedIdx,
                          "Accept branch (clears flag) must precede the reseed branch (sets flag).")

        // The background publish aborts on the reseed, before building any snapshot, and after the
        // config reload that determines the reseed.
        let helper = try Self.block(
            in: viewModel,
            from: "private func publishBackgroundRefreshArtifacts(operationID:",
            to: "private func didSnapshotIdentityChangeAfterSync()"
        )
        XCTAssertTrue(helper.contains("\"bg-premigration\""),
                      "Background publish must surface a premigration terminal, not silently publish.")
        XCTAssertTrue(helper.contains("guard !didReseedFilterLibraryOnLastLoad"),
                      "Background publish must abort when the reload reseeded the library.")
        let reloadIdx = try XCTUnwrap(helper.range(of: "loadPersistedConfiguration()")?.lowerBound)
        let abortIdx = try XCTUnwrap(helper.range(of: "\"bg-premigration\"")?.lowerBound)
        let buildIdx = try XCTUnwrap(helper.range(of: "Self.buildBackgroundPreparedSnapshot(")?.lowerBound)
        XCTAssertTrue(reloadIdx < abortIdx && abortIdx < buildIdx,
                      "Premigration abort must follow the reload and precede the snapshot build.")
    }

    func testPublishServiceCommitsBeforeFlipUnderLock() throws {
        let service = try Self.source(named: "FilterSnapshotPreparationService.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(service.contains("commitBeforeFlip: (@Sendable () throws -> Void)?"),
                      "persistArtifacts must accept a commitBeforeFlip hook.")
        // It must run inside the lock, AFTER the supersession check and BEFORE the pointer flip,
        // so the side commit (latest.json) is atomic with the flip and skipped on abort.
        let supersedeIdx = try XCTUnwrap(service.range(of: "return .abortedSuperseded")?.lowerBound)
        let commitIdx = try XCTUnwrap(service.range(of: "try commitBeforeFlip?()")?.lowerBound)
        let flipIdx = try XCTUnwrap(service.range(of: "try artifactStore.writeArtifactPointer(pointer)")?.lowerBound)
        XCTAssertLessThan(supersedeIdx, commitIdx, "commitBeforeFlip must run after the supersession check.")
        XCTAssertLessThan(commitIdx, flipIdx, "commitBeforeFlip must run before the pointer flip.")
    }

    func testForegroundWritesConfigBeforeFlippingArtifactPointer() throws {
        let viewModel = try Self.source(named: "AppViewModel.swift", in: "LavaSecApp")
        let block = try Self.block(in: viewModel, from: "private func persistSharedState(", to: "private func persistConfigurationOnly(")
        let configWriteIdx = try XCTUnwrap(block.range(of: "configurationData.write(to: configurationURL")?.lowerBound)
        let artifactIdx = try XCTUnwrap(block.range(of: "persistPreparedSnapshotArtifacts(snapshotToPersist)")?.lowerBound)
        XCTAssertLessThan(
            configWriteIdx, artifactIdx,
            "persistSharedState must write configuration.json (advancing the supersession token) BEFORE flipping the artifact pointer, so a background writer never observes a flip ahead of the generation bump."
        )
    }

    func testGarbageCollectionHasGraceRetentionAndAbortPathDoesNotGC() throws {
        let versioned = try Self.source(named: "FilterArtifactStoreVersioned.swift", in: "Sources/LavaSecCore")
        XCTAssertTrue(versioned.contains("graceInterval") && versioned.contains("contentModificationDate"),
                      "GC must never reap a freshly-staged peer dir (mtime/grace retention).")

        let service = try Self.source(named: "FilterSnapshotPreparationService.swift", in: "Sources/LavaSecCore")
        let abortBranch = try Self.block(in: service, from: "if let supersededWhileLocked, supersededWhileLocked(previousToken)", to: "return .abortedSuperseded")
        XCTAssertFalse(
            abortBranch.contains("collectVersionedGarbage"),
            "The supersession-abort path must not GC (it could evict a dir a live reader is mid-pass on, having published nothing)."
        )
    }

    // MARK: - Helpers

    private static func block(in source: String, from start: String, to end: String) throws -> String {
        let startRange = try XCTUnwrap(source.range(of: start), "missing anchor: \(start)")
        let endRange = try XCTUnwrap(
            source.range(of: end, range: startRange.upperBound ..< source.endIndex),
            "missing end anchor: \(end)"
        )
        return String(source[startRange.lowerBound ..< endRange.lowerBound])
    }

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        var sourceURL = packageRootURL
        for component in directoryName.split(separator: "/") {
            sourceURL.appendPathComponent(String(component))
        }
        sourceURL.appendPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
