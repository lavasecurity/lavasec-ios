import XCTest

@testable import LavaSecCore

/// The `BGAppRefreshTask` top-up, whose whole value is that it can run when the catalog refresh
/// cannot — and whose whole risk is doing something a short, network-free window must not do.
///
/// Plan Task 4, `lavasec-infra` `plans/2026-09-03-warm-index-coverage-plan.md`. Background
/// EXECUTION can only be validated on a device; what is pinnable is the declaration, the shape of
/// the request, and that the path stays sync-free.
final class BackgroundWarmTopUpSourceTests: XCTestCase {
    /// The identifier and background mode have to be declared, or iOS refuses the registration at
    /// launch — and a missing handler for a permitted identifier is a hard crash, not a no-op.
    func testInfoPlistDeclaresFetchModeAndTheTopUpIdentifier() throws {
        let plist = try readSource(.appInfoPlist)
        XCTAssertTrue(
            plist.contains("<string>com.lavasec.warm-topup</string>"),
            "a BGTaskScheduler identifier not in BGTaskSchedulerPermittedIdentifiers cannot register")
        XCTAssertTrue(
            plist.contains("<string>fetch</string>"),
            "BGAppRefreshTask needs the fetch background mode; processing alone covers only the "
                + "catalog refresh")
        XCTAssertTrue(
            plist.contains("<string>com.lavasec.catalog-refresh</string>")
                && plist.contains("<string>processing</string>"),
            "the existing refresh declaration must survive — the two tasks coexist")
    }

    /// AN APP-REFRESH REQUEST, NOT A PROCESSING ONE, and without a network requirement.
    ///
    /// The point of this task is that it compiles from the cache already on disk. Asking for
    /// connectivity would make it wait for a condition it does not need, which is exactly what
    /// keeps the 12-hour `BGProcessingTask` from filling this gap.
    func testTheRequestIsAShortNetworkFreeAppRefresh() throws {
        let app = try readSource(.lavaSecApp)
        let scheduleBlock = try sourceBlock(
            in: app,
            startingAt: "    static func scheduleNext() {\n        guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName) else { return }\n        let request = BGAppRefreshTaskRequest(",
            endingBefore: "    @MainActor\n    private static func handle(")

        XCTAssertTrue(
            scheduleBlock.contains("BGAppRefreshTaskRequest(identifier: taskIdentifier)"),
            "a BGProcessingTaskRequest would inherit the long-window scheduling this exists to avoid")
        XCTAssertFalse(
            sourceWithoutCommentLines(scheduleBlock).contains("requiresNetworkConnectivity"),
            "requiring connectivity would gate a cache-only compile on a condition it does not need")
        XCTAssertTrue(
            scheduleBlock.contains("guard !LavaSecAppGroup.sharedDefaults.bool(forKey: killSwitchDefaultsKeyName)"),
            "scheduling must honour the kill switch, like the catalog refresh's")
    }

    /// Registered at launch and scheduled on background, ALONGSIDE the refresh rather than
    /// replacing it. The two answer different questions: the refresh fetches, this one warms.
    func testBothBackgroundTasksAreRegisteredAndScheduled() throws {
        let app = try readSource(.lavaSecApp)
        XCTAssertTrue(app.contains("BackgroundCatalogRefresh.registerHandler()"))
        XCTAssertTrue(app.contains("BackgroundWarmTopUp.registerHandler()"))
        XCTAssertTrue(app.contains("BackgroundCatalogRefresh.scheduleNext()"))
        XCTAssertTrue(app.contains("BackgroundWarmTopUp.scheduleNext()"))
    }

    /// The exactly-once completion and cancel-on-expiration discipline the catalog refresh
    /// established. An overrun makes iOS throttle future runs of this identifier, which would
    /// quietly undo the entire point of adding a more frequent window.
    func testTheHandlerCompletesOnceAndCancelsOnExpiration() throws {
        let app = try readSource(.lavaSecApp)
        let handleBlock = try sourceBlock(
            in: app,
            startingAt: "        let work = Task { @MainActor in\n            // Re-read the kill switch",
            endingBefore: "private final class BGTaskBox")

        XCTAssertTrue(
            handleBlock.contains("completion.complete(success: !Task.isCancelled)"),
            "the run must report its own cancellation rather than claiming success")
        XCTAssertTrue(
            handleBlock.contains("work.cancel()"),
            "expiration must cancel the in-flight warm pass")
        XCTAssertTrue(
            handleBlock.contains("headless: true"),
            "a non-headless model installs side-effecting init work that could write this "
                + "short-lived instance's launch-time state over newer on-disk state")
    }

    /// IT MUST NOT SYNC. The safety that makes a sync-free warm sound lives inside
    /// `compileAndStageWarmArtifact` — a fresh-cache gate, catalog-only filters, and read-only
    /// treatment of the shared cache — which is why this path can skip the `bg-published`
    /// condition the refresh's own warm pass carries.
    ///
    /// A `syncCatalog` call here would turn a short, network-free window into the long, networked
    /// one it exists to complement, and would reintroduce exactly the non-committed-catalog hazard
    /// that gate protects against.
    func testTheTopUpWarmsFromTheHeldCacheWithoutSyncing() throws {
        let app = try readSource(.lavaSecApp)
        let workBlock = try sourceBlock(
            in: app,
            startingAt: "            let viewModel = AppViewModel(loadVPNState: false, headless: true)\n            await viewModel.topUpWarmIndexFromCachedCatalog()",
            endingBefore: "private final class BGTaskBox")
        XCTAssertFalse(
            sourceWithoutCommentLines(workBlock).contains("syncCatalog"),
            "the top-up must not sync — that is the catalog refresh's job and its long window")

        let viewModel = try readAppViewModelSource()
        let entry = try sourceBlock(
            in: viewModel,
            startingAt: "    func topUpWarmIndexFromCachedCatalog() async {",
            endingBefore: "    private func seedCatalogSourcesForRuleEstimateWithoutMigration() async {")
        XCTAssertTrue(
            entry.contains("await warmNonActiveFiltersInBackground(window: .appRefresh)"),
            "the top-up reuses the background warm pass rather than a second implementation of it")
        XCTAssertFalse(
            sourceWithoutCommentLines(entry).contains("syncCatalog"),
            "no sync on this path, at any layer. Comment lines are stripped first: the rationale "
                + "for not syncing names the very call it is refusing to make")
        XCTAssertTrue(
            entry.contains("guard isHeadless"),
            "sidecar warming is the background's job; the foreground warms via the library path")
        XCTAssertTrue(
            entry.contains("await seedCatalogSourcesForRuleEstimateWithoutMigration()"),
            "estimatedRuleCount sums the catalog's per-source entry counts, and this handler builds "
                + "its model with loadVPNState: false and runs no sync — so without this the "
                + "estimate collapses to the filter's own domain counts and the pre-compile budget "
                + "skip never fires, leaving only the post-compile break on a ~30s window")

        // ORDER: the catalog basis has to be in place BEFORE the pass reads it.
        let load = try XCTUnwrap(entry.range(of: "await seedCatalogSourcesForRuleEstimateWithoutMigration()"))
        let warm = try XCTUnwrap(entry.range(of: "await warmNonActiveFiltersInBackground(window:"))
        XCTAssertLessThan(
            load.lowerBound, warm.lowerBound,
            "loading the catalog after the pass is the same as not loading it")
    }

    /// A READ-ONLY TOP-UP MUST NOT DELETE THE CATALOG.
    ///
    /// `loadCachedCatalogIfAvailable` is the obvious way to fill the estimate's inputs and is the
    /// wrong one here: it begins with `migrateLowRiskLaunchCacheIfNeeded`, which REMOVES
    /// `latest.json` whenever the cache predates a required launch source. The launch path can
    /// afford that because `syncCatalogIfStale()` follows and re-fetches; this handler deliberately
    /// runs no sync, so calling it would erase the last committed catalog and break offline startup
    /// and every warm reuse until some later network refresh (Codex review, PR #646).
    func testTheTopUpSeedsTheEstimateWithoutMigratingTheCache() throws {
        let viewModel = try readAppViewModelSource()
        let entry = try sourceBlock(
            in: viewModel,
            startingAt: "    func topUpWarmIndexFromCachedCatalog() async {",
            endingBefore: "    private func seedCatalogSourcesForRuleEstimateWithoutMigration() async {")
        XCTAssertFalse(
            sourceWithoutCommentLines(entry).contains("await loadCachedCatalogIfAvailable()"),
            "that call migrates before it reads, and migration deletes latest.json on a path with "
                + "no sync behind it to repair the deletion")

        let seed = try sourceBlock(
            in: viewModel,
            startingAt: "    private func seedCatalogSourcesForRuleEstimateWithoutMigration() async {",
            endingBefore: "    func warmNonActiveFiltersInBackground(")
        XCTAssertTrue(
            seed.contains("loadCachedCatalogMetadata()"),
            "a read of the persisted catalog, which is all the estimate needs")
        XCTAssertFalse(
            sourceWithoutCommentLines(seed).contains("migrateLowRiskLaunchCacheIfNeeded"),
            "no migration on a path that cannot repair what it removes")
        XCTAssertTrue(
            seed.contains("catalogSourcesByID = Dictionary("),
            "only the one map the estimate reads — a wider apply is how a short-lived headless "
                + "model persists launch-time state over newer on-disk state")
        XCTAssertFalse(
            sourceWithoutCommentLines(seed).contains("cachedBlockRuleSets ="),
            "the rule sets are not needed for the estimate and are not this model's to write")
    }

    /// THE BUDGET HAS TO MEASURE WHAT IT SPENDS.
    ///
    /// The pre-compile estimate and the post-compile accumulator were counting different things.
    /// Every warm compile calls `loadCached` with `includesGuardrails` at its default of true —
    /// ungated on the filter having allowed domains — so it parses the FULL guardrail union; and the
    /// figure the loop then adds to `rulesCompiled` is `summary.tierBudgetRuleCount`, defined as
    /// merged block rules plus the FULL guardrail rule set plus allowed plus blocked. With
    /// guardrails absent from the estimate, a filter could measure under the app-refresh ceiling and
    /// compile substantially past it — overrunning a ~30 s window, and repeated expirations are what
    /// makes iOS throttle a task identifier (Codex review, PR #646).
    ///
    /// A per-compile constant, so it shifts every candidate equally and reorders nothing: it is
    /// invisible in the ordering and visible only in the level the budget is enforced at.
    func testTheEstimateCountsTheCatalogGuardrails() throws {
        let viewModel = try readAppViewModelSource()
        let estimate = try sourceBlock(
            in: viewModel,
            startingAt: "    private func estimatedRuleCount(forFilterID filterID: String) -> Int {",
            endingBefore: "    func topUpWarmIndexFromCachedCatalog() async {")
        XCTAssertTrue(
            estimate.contains("catalogGuardrailEntryCount"),
            "the compile pays for the guardrail union on every candidate; an estimate that omits "
                + "it is compared against a budget spent in a larger unit")

        // And the headless path has to SEED it, for the same reason it has to seed the sources: this
        // model runs with loadVPNState: false and no sync, so nothing else fills either.
        let seed = try sourceBlock(
            in: viewModel,
            startingAt: "    private func seedCatalogSourcesForRuleEstimateWithoutMigration() async {",
            endingBefore: "    func warmNonActiveFiltersInBackground(")
        XCTAssertTrue(
            seed.contains("catalogGuardrailEntryCount = catalog.guardrailEntryCount"),
            "seeding the sources without the guardrails leaves the estimate short by the one term "
                + "every candidate pays")

        // Seeded BEFORE the sources bail out: a catalog can carry guardrails with an empty sources
        // array, and the early return for empty sources must not skip the guardrail term.
        let guardrailSeed = try XCTUnwrap(seed.range(of: "catalogGuardrailEntryCount ="))
        let sourcesGuard = try XCTUnwrap(seed.range(of: "guard !catalog.sources.isEmpty"))
        XCTAssertLessThan(
            guardrailSeed.lowerBound, sourcesGuard.lowerBound,
            "an empty sources array must not also discard the guardrail size")
    }

    /// The guardrail SIZE is public; the guardrail ARRAY stays package-scoped.
    ///
    /// The app needs to budget against the guardrail work, not to enumerate or present the tier —
    /// `guardrails[]` is the structural source of truth for what counts as safety-critical
    /// (`CatalogBlocklistSource.markedAsGuardrail`), and widening it to public to obtain one integer
    /// would hand the app target the whole tier.
    func testTheCatalogPublishesItsGuardrailSizeAsASum() throws {
        let published = Date(timeIntervalSince1970: 1_700_000_000)
        func makeSource(id: String, entryCount: Int, category: String) -> CatalogBlocklistSource {
            CatalogBlocklistSource(
                id: id, name: id, category: category, riskLevel: "low", defaultEnabled: false,
                licenseName: "MIT", attribution: "test",
                projectURL: URL(string: "https://example.com")!,
                sourceURL: URL(string: "https://example.com/\(id).txt")!,
                versionID: "\(id)-v1", entryCount: entryCount, byteSize: entryCount * 16,
                sourceHash: "hash-\(id)", acceptedSourceHashes: [], normalizedHash: "hash-\(id)",
                publishedAt: published, redistributionMode: "allowed", parseFormat: .plainDomains,
                licenseTextURL: nil, noticeURL: nil)
        }

        let catalog = BlocklistCatalog(
            schemaVersion: 2, catalogVersion: "v1", generatedAt: published,
            sources: [makeSource(id: "source-a", entryCount: 100_000, category: "ads")],
            guardrails: [
                makeSource(id: "guardrail-a", entryCount: 40_000, category: "threat"),
                makeSource(id: "guardrail-b", entryCount: 2_000, category: "threat")
            ])
        XCTAssertEqual(
            catalog.guardrailEntryCount, 42_000,
            "the sum of the guardrail sources, and only those — the selectable sources are budgeted "
                + "per filter from the enabled set")

        let noGuardrails = BlocklistCatalog(
            schemaVersion: 2, catalogVersion: "v1", generatedAt: published,
            sources: [makeSource(id: "source-a", entryCount: 100_000, category: "ads")],
            guardrails: [])
        XCTAssertEqual(
            noGuardrails.guardrailEntryCount, 0,
            "no guardrails is zero added work, not an unknown quantity")
    }

    /// THE INDEX'S SECOND WRITER NEEDS CROSS-PROCESS SINGLE-FLIGHT.
    ///
    /// Before this PR the warm pass had one caller and iOS does not re-enter a single BGTask
    /// identifier, so single-writer held by construction. A `BGAppRefreshTask` can run alongside
    /// the processing task, and both of the pass's writes replace the whole sidecar — so two runs
    /// computing from the same prior state end with the later write dropping the earlier one's
    /// freshly staged entries. Fewer warm artifacts is the exact condition the pass exists to
    /// remove (Codex review, PR #646 and infra #209).
    func testTheWarmPassIsSingleFlightAcrossProcesses() throws {
        let viewModel = try readAppViewModelSource()
        let wrapper = try sourceBlock(
            in: viewModel,
            startingAt: "    func warmNonActiveFiltersInBackground(",
            endingBefore: "    private func waitForWarmPassToFinish(")

        XCTAssertTrue(
            wrapper.contains("FilterPublishLock.tryAcquireExclusiveDescriptor("),
            "an in-process actor is not sufficient — the two handlers may be in different BGTask "
                + "lifetimes, so exclusion has to be an app-group flock")
        XCTAssertTrue(
            wrapper.contains("LavaSecAppGroup.backgroundWarmIndexLockFilename"),
            "a lock distinct from the publish lock: this one is held across a multi-second compile "
                + "loop, and sharing the publish lock would stall every switch behind a warm pass")
        XCTAssertTrue(
            wrapper.contains("defer { FilterPublishLock.releaseDescriptor(descriptor) }"),
            "the descriptor must be released on every exit path, including a thrown cancellation")

        // AND IN-PROCESS, which is the likely case rather than the exotic one: both BGTask handlers
        // run in the app process, and on Darwin an flock held by one process via a different
        // descriptor does not reliably conflict with itself — FilterPublishLockTests spawns a CHILD
        // PROCESS for its contention proof precisely because of that. The file lock alone would let
        // the common case through.
        XCTAssertTrue(
            wrapper.contains("if Self.isWarmPassInFlight {"),
            "same-process concurrency is what these two handlers actually produce, and flock does "
                + "not reliably exclude a process from itself")
        let flag = try XCTUnwrap(wrapper.range(of: "Self.isWarmPassInFlight = true"))
        let acquire = try XCTUnwrap(wrapper.range(of: "FilterPublishLock.tryAcquireExclusiveDescriptor("))
        XCTAssertLessThan(
            flag.lowerBound, acquire.lowerBound,
            "the in-process flag is set before the file lock is attempted; reversed, two same-process "
                + "passes could both pass the flock and then both set the flag")

        // DEGRADE-ABORT, never degrade-open. The pass rewrites the sidecar wholesale, so a run that
        // cannot take the lock must do nothing rather than proceed unprotected.
        let contended = try XCTUnwrap(wrapper.range(of: "warm-pass-skipped"))
        let call = try XCTUnwrap(wrapper.range(of: "await warmNonActiveFiltersInBackgroundUnderLock(window: window)"))
        XCTAssertLessThan(
            contended.lowerBound, call.lowerBound,
            "the contended branch returns before the pass runs, or the lock buys nothing")
    }

    /// AUTHORITATIVE STATE, OR NO WRITE (INV-PERSIST-1).
    ///
    /// A launch between reboot and first unlock reads the shared pair as existing-but-unreadable
    /// and seeds a placeholder. The pass enumerates candidates from the in-memory library and then
    /// rewrites the sidecar wholesale, so running against that placeholder drops every real warm
    /// entry. The catalog refresh inherits the protection structurally — its warm pass runs only
    /// after a publish that degrade-ABORTs — and a sync-free top-up does not, so the guard is
    /// stated in the pass where it covers BOTH callers (Codex review, PR #646).
    func testTheWarmPassRefusesToWriteFromPlaceholderState() throws {
        let viewModel = try readAppViewModelSource()
        let pass = try sourceBlock(
            in: viewModel,
            startingAt: "    private func warmNonActiveFiltersInBackgroundUnderLock(",
            endingBefore: "        let activeID = library.activeFilterID")

        XCTAssertTrue(
            pass.contains("guard !sharedStateUnavailableAtLoad else {"),
            "every peer write path guards on this flag; a wholesale sidecar rewrite is not the one "
                + "that gets to skip it")

        // A RESEEDED LIBRARY IS PLACEHOLDER STATE BY A DIFFERENT DOOR, and the flag above does not
        // see it: a usable but old-schema library is reseeded to defaults WITHOUT raising
        // `sharedStateUnavailableAtLoad`. `publishBackgroundRefreshArtifacts` already refuses on
        // this one (`bg-premigration`), so a wholesale sidecar rewrite must too — otherwise it
        // drops entries for the still-persisted filters and adds entries no on-disk switch can
        // address (Codex review, PR #646).
        XCTAssertTrue(
            pass.contains("guard !didReseedFilterLibraryOnLastLoad else {"),
            "readable-but-not-yet-the-user's state is still placeholder state for a wholesale "
                + "rewrite")
    }

    /// A CONTENDED PASS IS RE-RUN, NOT DROPPED.
    ///
    /// The two callers are not equally valuable, and abort-on-contention silently prefers the wrong
    /// one. The catalog refresh's post-publish pass follows a commit that invalidated every warm
    /// artifact, so discarding it because the top-up happens to hold the flag leaves the newly
    /// committed catalog with no warm coverage — while the top-up's own artifacts, built for the
    /// previous catalog, are now rejected by the reuse gate. The index ends emptier than before
    /// either pass ran (Codex review, PR #646).
    func testAContendedInProcessPassIsRerunRatherThanDiscarded() throws {
        let viewModel = try readAppViewModelSource()
        let wrapper = try sourceBlock(
            in: viewModel,
            startingAt: "    func warmNonActiveFiltersInBackground(",
            endingBefore: "    private func waitForWarmPassToFinish(")

        XCTAssertTrue(
            wrapper.contains("Self.warmPassRerunRequestedWindow = Self.widerWarmWindow("),
            "the contended caller records that a pass is still owed AND the window it is owed in — "
                + "a bare flag let the holder service a processing request under its own fetch "
                + "window's budget and refusals")
        XCTAssertTrue(
            wrapper.contains("if let requested = Self.warmPassRerunRequestedWindow,"),
            "the holder drains a queued request on the way out")
        XCTAssertTrue(
            wrapper.contains("!Task.isCancelled,"),
            "cancellation-gated like every other app-group mutation on this path")
        XCTAssertTrue(
            wrapper.contains("Self.widerWarmWindow(requested, window) == window"),
            "a request is drained only by a window that can satisfy it: a fetch task running a "
                + "processing request would execute tier-cap policy in a ~30s window, which is the "
                + "livelock the split exists to prevent")
        XCTAssertTrue(
            wrapper.contains("if Self.widerWarmWindow(Self.warmPassRerunRequestedWindow, window) == window {"),
            "and it is CONSUMED only by such a window — clearing unconditionally discards a "
                + "processing request a cancelled owner deliberately retained")

        // BOUNDED TO ONE. A loop would let two handlers ping-pong, and a second rerun would be
        // recomputing against state no newer than the first already read.
        XCTAssertFalse(
            sourceWithoutCommentLines(wrapper).contains("while Self.warmPassRerunRequestedWindow"),
            "one rerun, not a loop")

        // THE TWO WINDOWS CONTEND DIFFERENTLY. The short one hands its work to the holder; the long
        // one waits, because the holder it would hand to may be the short window, which can expire
        // mid-pass and take the queued rerun with it — and the requester has by then returned past
        // its only warm call, leaving the catalog it just published with no coverage.
        XCTAssertTrue(
            wrapper.contains("guard let waitBudget = window.contentionWaitBudget else {"),
            "the contention policy belongs to the window, not to one constant for both callers")
        XCTAssertTrue(
            wrapper.contains("await waitForWarmPassToFinish(within: waitBudget)"),
            "the long window waits out the holder rather than handing over its post-publish pass")

        // The flag is cleared BEFORE the pass it covers, so a request arriving mid-pass is not
        // swallowed by the clear that belongs to the previous one.
        let clear = try XCTUnwrap(
            wrapper.range(of: "if Self.widerWarmWindow(Self.warmPassRerunRequestedWindow, window) == window {"))
        let firstPass = try XCTUnwrap(
            wrapper.range(of: "await warmNonActiveFiltersInBackgroundUnderLock(window: window)"))
        XCTAssertLessThan(
            clear.lowerBound, firstPass.lowerBound,
            "clearing after the pass would discard a request that arrived while it ran")

        // CROSS-PROCESS contention still aborts: no in-process holder exists to drain a flag, and
        // the other process is mid-pass against the same on-disk state.
        XCTAssertTrue(
            wrapper.contains("\"reason\": \"contended\""),
            "the cross-process branch is a genuine abort and says so")
    }

    /// WARMING WITHOUT DRAINING LEAVES THE SWITCH STILL WAITING.
    ///
    /// A Focus switch that deferred for a missing artifact leaves its marker in
    /// `PendingFilterSwitchStore`. Topping up makes the artifact exist but applies nothing, so the
    /// switch keeps waiting for a foreground — with every diagnostic reporting health. The catalog
    /// refresh warms then drains for exactly this reason (Codex review, PR #646).
    func testTheTopUpDrainsAPendingSwitchAfterWarming() throws {
        let app = try readSource(.lavaSecApp)
        let workBlock = try sourceBlock(
            in: app,
            startingAt: "            let viewModel = AppViewModel(loadVPNState: false, headless: true)\n            await viewModel.topUpWarmIndexFromCachedCatalog()",
            endingBefore: "private final class BGTaskBox")

        XCTAssertTrue(
            workBlock.contains("FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh()"),
            "re-warming without rerunning the switch engine restores coverage and applies nothing")

        // AFTER the top-up: the drain is warm-only, so a target this run just warmed is one it can
        // now commit. Draining first would find the same missing artifact and defer again.
        let topUp = try XCTUnwrap(workBlock.range(of: "await viewModel.topUpWarmIndexFromCachedCatalog()"))
        let drain = try XCTUnwrap(
            workBlock.range(of: "FocusSwitchEnvironment.drainPendingFilterSwitchAfterBackgroundRefresh()"))
        XCTAssertLessThan(
            topUp.lowerBound, drain.lowerBound,
            "draining before the warm pass finds the same missing artifact and defers again")
        XCTAssertTrue(
            workBlock.contains("if !Task.isCancelled {"),
            "an expired BGTask must not start the drain; the marker survives to the next window")
    }

    /// The warm-pass shape has to survive export, or a capture says a pass ran without saying which
    /// window, what it refused, or against what budget.
    ///
    /// An emitted-but-unlisted detail key exports as `_withheld` — a defect this codebase has
    /// shipped three times, which is why the keys go in with the events rather than after them.
    func testTheWarmPassShapeReachesABugReport() throws {
        let bundle = try readSource(.bugReportBundle)
        let allowlist = try sourceBlock(
            in: bundle,
            startingAt: "private static let allowedDetailKeys: Set<String> = [",
            endingBefore: "private static let structuralKeys")

        for key in ["window", "owner", "refused", "perRunRuleBudget", "guardrailRules"] {
            XCTAssertTrue(
                allowlist.contains("\"\(key)\""),
                "\(key) is emitted by the warm-pass events but not exported — the capture would "
                    + "carry `_withheld` where the pass's shape should be")
        }
    }
}
