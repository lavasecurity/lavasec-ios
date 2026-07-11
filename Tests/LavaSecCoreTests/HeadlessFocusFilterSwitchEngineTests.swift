import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

/// Unit coverage for the headless Focus-switch DECISION logic — the gate, reseed/target guards, the
/// already-active record-and-nudge, and the Hybrid defer paths — driven against a seeded temp App Group
/// directory. This path was previously only reachable through `AppViewModel` (introspection/device only);
/// relocating it to `HeadlessFocusFilterSwitchEngine` makes it directly unit-testable (LAV-100 Phase 4).
///
/// The COMMITTED (warm flip) path needs a real staged warm artifact + a fresh cached catalog, so it is
/// validated by the source-introspection wiring tests + the internal-TestFlight behavioral test; here we
/// assert every branch that ends in disallowed / alreadyActive / deferred and the marker + signal effects.
final class HeadlessFocusFilterSwitchEngineTests: XCTestCase {
    func testOutcomeRawValuesRemainStableForPersistedDiagnostics() {
        XCTAssertEqual(HeadlessFocusSwitchOutcome.committed.rawValue, "committed")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.deferred.rawValue, "deferred")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.alreadyActive.rawValue, "alreadyActive")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.disallowed.rawValue, "disallowed")
    }

    private final class SignalSpy: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func post(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var posted: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }

    private struct Harness {
        let env: HeadlessFocusFilterSwitchEngine.Environment
        let defaults: UserDefaults
        let spy: SignalSpy
        let dir: URL
    }

    private func makeHarness(now: Date = Date(timeIntervalSinceReferenceDate: 10_000)) -> Harness {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("hfse-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "hfse-\(UUID().uuidString)")!
        let spy = SignalSpy()
        let env = HeadlessFocusFilterSwitchEngine.Environment(
            containerURL: dir,
            configurationURL: dir.appendingPathComponent("app-configuration.json"),
            filterLibraryURL: dir.appendingPathComponent("filter-library.json"),
            catalogCacheURL: dir.appendingPathComponent("catalog-cache", isDirectory: true),
            backgroundWarmIndexURL: dir.appendingPathComponent("background-warm-index.json"),
            publishLockURL: dir.appendingPathComponent("publish.lock"),
            focusSwitchLockURL: dir.appendingPathComponent("focus.lock"),
            configurationWriteLockURL: dir.appendingPathComponent("config-write.lock"),
            pendingMarkerLockURL: dir.appendingPathComponent("marker.lock"),
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot-compact.json",
            defaults: defaults,
            catalogSyncFreshnessInterval: 7 * 24 * 60 * 60,
            now: { now },
            postSignal: { spy.post($0) },
            log: { _, _ in }
        )
        return Harness(env: env, defaults: defaults, spy: spy, dir: dir)
    }

    private func seedConfiguration(_ harness: Harness, isPaid: Bool) {
        var config = AppConfiguration(enabledBlocklistIDs: ["s1"], customBlocklists: [], configurationGeneration: 1)
        config.isPaid = isPaid
        let data = try! JSONEncoder().encode(config)
        try! data.write(to: harness.env.configurationURL)
    }

    private func seedLibrary(_ harness: Harness, active: String, ids: [String]) {
        let filters = ids.map { Filter(id: $0, name: $0.uppercased(), enabledBlocklistIDs: ["s1"]) }
        var lib = FilterLibrary(filters: filters, activeFilterID: active)
        lib.configurationGeneration = 1
        let data = try! JSONEncoder().encode(lib)
        try! data.write(to: harness.env.filterLibraryURL)
    }

    private func cleanup(_ harness: Harness) {
        try? FileManager.default.removeItem(at: harness.dir)
    }

    // MARK: - Gate (fail-closed security boundary)

    func testFreeUserIsAllowedToSwitch() async {
        // Focus auto-switch is available to ALL tiers — the Plus paywall was dropped. A free user's switch
        // is NOT gated out: with no warm artifact it simply defers to the foreground reconcile (records the
        // marker + nudges), exactly like a Plus user would.
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: false)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred, "A free user is allowed to switch (no warm artifact ⇒ defer, not disallowed).")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2",
                       "A free-tier switch must record the pending marker (no longer Plus-gated).")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName])
        // The diagnostic records the SPECIFIC defer reason (the Release-visible signal for closed-app debugging).
        let diag = FocusSwitchDiagnostics.last(in: h.defaults)
        XCTAssertEqual(diag?.outcome, "deferred")
        XCTAssertEqual(diag?.reason, "deferred-no-warm-artifact",
                       "The diagnostic must record WHY it deferred so a closed-app switch is diagnosable on Release.")
    }

    func testAuthToEditDisallowReasonIsRecorded() async {
        // The disallow reason distinguishes auth-to-edit from a config-fallback / target-unavailable refusal.
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults)

        _ = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        let diag = FocusSwitchDiagnostics.last(in: h.defaults)
        XCTAssertEqual(diag?.outcome, "disallowed")
        XCTAssertEqual(diag?.reason, "disallowed-auth-to-edit")
    }

    func testAuthToEditIsDisallowedAndRecordsNothing() async {
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults)

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .disallowed, "Auth-to-edit must fail closed in the unattended path.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults))
        XCTAssertTrue(h.spy.posted.isEmpty)
    }

    func testMissingConfigurationFailsClosed() async {
        // If app-configuration.json is absent/corrupt (but the library is valid), loadState would otherwise
        // fall back to a DEFAULT config; committing a switch from it would clobber the user's real
        // device-global settings (resolver/protection/etc.). The engine must refuse — treat the config-load
        // failure as a reseed. (Before the Plus gate was dropped this was caught implicitly by isPaid=false;
        // now it's explicit — Codex.) Seed ONLY the library, no configuration file.
        let h = makeHarness(); defer { cleanup(h) }
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .disallowed, "A missing/corrupt configuration must fail closed, not switch from defaults.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "A fail-closed load must not record a marker.")
        XCTAssertTrue(h.spy.posted.isEmpty)
    }

    func testMissingTargetIsDisallowed() async {
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "ghost", env: h.env)

        XCTAssertEqual(outcome, .disallowed)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults))
    }

    // MARK: - Reseed guard

    func testReseedFromMissingLibraryIsDisallowed() async {
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true) // Plus passes the gate; the missing library forces a reseed.
        // No filter-library.json written ⇒ loadState reseeds the defaults (didReseed == true).

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "filter-balanced", env: h.env)

        XCTAssertEqual(outcome, .disallowed, "A reseeded (un-persisted) library must refuse — never write defaults over real state.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "The reseed guard precedes the marker record.")
    }

    // MARK: - Already active

    func testAlreadyActiveRecordsMarkerAndNudges() async {
        let now = Date(timeIntervalSinceReferenceDate: 55_000)
        let h = makeHarness(now: now); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f1", env: h.env)

        XCTAssertEqual(outcome, .alreadyActive)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults),
                       PendingFilterSwitchRequest(targetFilterID: "f1", requestedAt: now),
                       "Already-active still records the newest target so the foreground can't switch away.")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName])
    }

    // MARK: - Focus-off is a no-op (panel P1): the off-edge can't attribute the marker to a Focus
    //
    // There is deliberately NO cancel-on-Focus-off engine API. `SetFocusFilterIntent.perform(nil)` carries no
    // Focus identity, so a blind clear could drop a DIFFERENT, still-active Focus's just-recorded switch. The
    // single shared marker holds only the NEWEST intent; the cross-Focus overwrite below shows a later Focus's
    // request correctly supersedes an earlier one, and nothing in the engine clears it on deactivation.

    func testLaterFocusRequestSupersedesEarlierMarkerAndNothingClearsItOnFocusOff() async {
        let now = Date(timeIntervalSinceReferenceDate: 91_000)
        let h = makeHarness(now: now); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2", "f3"])
        // Focus A switches to f2 — no warm artifact seeded ⇒ deferred, marker recorded.
        let a = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
        XCTAssertEqual(a, .deferred)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")

        // Focus B then defers a switch to f3 — its marker supersedes A's (newest intent wins).
        let b = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f3", env: h.env)
        XCTAssertEqual(b, .deferred)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f3",
                       "The latest Focus request must be the live marker (no engine cancel can drop it on a Focus-off edge).")
    }

    // MARK: - Committed warm-flip (behavioral harness)
    //
    // Seeds a real staged warm artifact + fresh cached catalog so the engine reaches the COMMIT path —
    // the warm flip that the relocation made unit-testable for the first time. (The in-lock catalog-moved
    // veto + generation-superseded fence + generic-throw rollback are RACE paths that need timing/fault
    // injection a single-threaded unit test can't deterministically produce; they stay pinned by the
    // FocusFilterSwitchWiringSourceTests structural assertions + the internal-TestFlight behavioral test.)

    /// Build a fresh cached catalog + stage a warm artifact for `targetEnabledSourceIDs`, returning the
    /// staged token + the URLs the engine Environment needs. Mirrors FilterSnapshotPreparationServiceTests' Fixture.
    private func stageWarmArtifact(
        cacheDir: URL,
        containerDir: URL,
        catalogVersion: String = "test-1",
        catalogGeneratedAt: Date = Date()
    ) async throws -> (token: String, configuration: AppConfiguration) {
        let payload = Data("ads.example.com\ntrack.example.com\n".utf8)
        let checksum = BlocklistCatalogSynchronizer.sha256Hex(of: payload)
        let source = CatalogBlocklistSource(
            id: "source-a", name: "Source A", category: "ads", riskLevel: "low", defaultEnabled: true,
            licenseName: "MIT", attribution: "test",
            projectURL: URL(string: "https://example.com")!, sourceURL: URL(string: "https://example.com/list.txt")!,
            versionID: "source-a-v1", entryCount: 2, byteSize: payload.count, sourceHash: checksum,
            acceptedSourceHashes: [CatalogAcceptedSourceHash(sha256: checksum)], normalizedHash: checksum,
            publishedAt: Date(), redistributionMode: "allowed", parseFormat: .plainDomains,
            licenseTextURL: nil, noticeURL: nil
        )
        let catalog = BlocklistCatalog(
            schemaVersion: 2, catalogVersion: catalogVersion, generatedAt: catalogGeneratedAt,
            sources: [source], guardrails: []
        )
        let catalogDir = cacheDir.appendingPathComponent("catalog", isDirectory: true)
        try FileManager.default.createDirectory(at: catalogDir, withIntermediateDirectories: true)
        try BlocklistCatalogSynchronizer.makeJSONEncoder().encode(catalog)
            .write(to: catalogDir.appendingPathComponent("latest.json"))

        var configuration = AppConfiguration(enabledBlocklistIDs: ["source-a"])
        configuration.isPaid = true
        let service = FilterSnapshotPreparationService(
            synchronizer: BlocklistCatalogSynchronizer(
                catalogURL: URL(string: "https://example.com/catalog.json")!,
                cacheDirectoryURL: cacheDir,
                dataFetcher: { url in
                    if url.lastPathComponent == "list.txt" { return payload }
                    throw URLError(.cannotFindHost)
                }
            )
        )
        let prepared = try await service.prepare(
            configuration: configuration, customSources: [], catalogFreshnessMaxAge: 3_600
        )
        let pointer = try await service.stageArtifacts(
            prepared.snapshot,
            containerURL: containerDir,
            snapshotFilename: "filter-snapshot.json",
            compactSnapshotFilename: "filter-snapshot.compact"
        )
        return (pointer.token, configuration)
    }

    /// Write a valid 2-filter library (active `f1` empty, target `f2` carrying `targetEnabled` + `token`)
    /// + the matching active configuration to the container, at a non-zero generation (no lost-write race).
    private func seedLibraryWithWarmTarget(_ h: Harness, token: String, targetEnabled: Set<String>) throws {
        let f1 = Filter(id: "f1", name: "F1", enabledBlocklistIDs: [])
        let f2 = Filter(id: "f2", name: "F2", enabledBlocklistIDs: targetEnabled, lastCompiledToken: token)
        var library = FilterLibrary(filters: [f1, f2], activeFilterID: "f1")
        library.configurationGeneration = 1
        try JSONEncoder().encode(library).write(to: h.env.filterLibraryURL)

        var config = AppConfiguration(enabledBlocklistIDs: [], configurationGeneration: 1) // mirrors active f1
        config.isPaid = true
        try JSONEncoder().encode(config).write(to: h.env.configurationURL)
    }

    func testCommittedWarmFlipPublishesTargetAndLeavesMarker() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 90_000)
        let h = makeHarness(now: now); defer { cleanup(h) }
        // catalogCacheURL must be where the fixture wrote the catalog; reuse the harness dir's cache path.
        let staged = try await stageWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .committed, "A warm target with the app inactive must commit immediately.")
        // On-disk library now selects the target and the artifact pointer flipped to the staged token.
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f2", "The committed switch must make the target active on disk.")
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: h.env.configurationURL))
        XCTAssertGreaterThan(config.configurationGeneration, 1, "The commit must bump the configuration generation.")
        let pointerToken = FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer()?.token
        XCTAssertEqual(pointerToken, staged.token, "The artifact pointer must flip to the validated warm token.")
        // The marker is LEFT for the foreground reconcile (the headless path never clears it).
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2",
                       "A committed headless switch must leave the marker for the foreground reconcile.")
        // The privacy-safe diagnostic record reflects the committed outcome.
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.outcome, "committed")
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.targetFilterID, "f2")
        // A COMMITTED switch must nudge the foreground reconcile (Codex P1): the state-agnostic commit can
        // land while the app is foreground-active, so a resident AppViewModel must be woken to adopt the
        // committed target + clear the marker (else its in-memory/UI state stays stale until a scene change).
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName],
                       "A committed headless switch must post the foreground-reconcile nudge.")
    }

    func testStaleCachedCatalogDefersInsteadOfFlipping() async throws {
        let h = makeHarness(); defer { cleanup(h) }
        let staged = try await stageWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        // Make the cached catalog STALE on disk (freshness is the latest.json mtime, well past the env's
        // 7-day window) so the warm-reuse gate rejects it and the headless path defers (cold-compile on the
        // foreground) rather than flip a stale basis.
        let latestURL = h.env.catalogCacheURL.appendingPathComponent("catalog/latest.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: latestURL.path)
        try seedLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred, "A stale cached catalog must defer (cold-compile on the foreground), not warm-flip.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1", "A deferral must not change the on-disk active filter.")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")
    }

    func testNoWarmArtifactDefersAndKeepsMarker() async {
        let h = makeHarness(); defer { cleanup(h) }
        seedConfiguration(h, isPaid: true)
        seedLibrary(h, active: "f1", ids: ["f1", "f2"])
        // App is NOT foreground-active and there is no staged warm artifact / fresh cached catalog,
        // so the headless path defers (it never cold-compiles inline).

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2",
                       "The durable marker is the correctness guarantee even when the immediate commit is skipped.")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName])
    }
}
