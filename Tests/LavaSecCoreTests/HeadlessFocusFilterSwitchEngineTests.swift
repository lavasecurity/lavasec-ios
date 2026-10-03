import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

private actor FocusSwitchFeedbackSpy {
    private var values: [String] = []
    func record(committed: Bool, label: String) { values.append("\(committed):\(label)") }
    func recorded() -> [String] { values }
}

private final class FocusDiagnosticClearProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let clearedAt: Date
    private let postClearNow: Date
    private var defaults: UserDefaults?
    private var orderingLockURL: URL?
    private var nowValue: Date

    init(clearedAt: Date, decisionAt: Date) {
        self.clearedAt = clearedAt
        self.postClearNow = clearedAt.addingTimeInterval(1)
        self.nowValue = decisionAt
    }

    func install(defaults: UserDefaults, orderingLockURL: URL) {
        lock.lock()
        self.defaults = defaults
        self.orderingLockURL = orderingLockURL
        lock.unlock()
    }

    func clear() {
        lock.lock()
        let defaults = self.defaults
        let orderingLockURL = self.orderingLockURL
        nowValue = postClearNow
        lock.unlock()
        guard let defaults else { return }
        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL, now: { self.clearedAt })
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return nowValue
    }
}

/// Unit coverage for the headless Focus-switch DECISION logic — the gate, reseed/target guards, the
/// already-active record-and-nudge, and the Hybrid defer paths — driven against a seeded temp App Group
/// directory. This path was previously only reachable through `AppViewModel` (introspection/device only);
/// relocating it to `HeadlessFocusFilterSwitchEngine` makes it directly unit-testable (LAV-100 Phase 4).
///
/// The COMMITTED (warm flip) path needs a real staged warm artifact + a fresh cached catalog, so it is
/// validated by the source-introspection wiring tests + the internal-TestFlight behavioral test; here we
/// assert every branch that ends in disallowed / alreadyActive / deferred and the marker + signal effects.
final class HeadlessFocusFilterSwitchEngineTests: XCTestCase {
    func testSwitchFeedbackCarriesSavedEmojiWithoutChangingStoredIdentity() async throws {
        for refused in [false, true] {
            let feedback = FocusSwitchFeedbackSpy()
            let h = makeFocusSwitchEngineHarness(notifySwitchOutcome: {
                await feedback.record(committed: $0, label: $1)
            })
            defer { cleanupFocusSwitchHarness(h) }
            let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
            try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
            var library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
            var target = try XCTUnwrap(library.filter(id: "f2"))
            target.name = "My Work"
            target.emoji = "👩🏽‍💻"
            library.update(target)
            try JSONEncoder().encode(library).write(to: h.env.filterLibraryURL)
            if refused {
                SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults,
                    projectionURL: SecurityProtectedSurfaceStorage.projectionURL(containerURL: h.dir))
            }

            let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
            XCTAssertEqual(outcome, refused ? .disallowed : .committed)
            let recorded = await feedback.recorded()
            XCTAssertEqual(recorded, ["\(!refused):👩🏽‍💻 My Work"])
            let persisted = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
            XCTAssertEqual(persisted.filter(id: "f2")?.name, "My Work")
            XCTAssertEqual(persisted.filter(id: "f2")?.emoji, "👩🏽‍💻")
            XCTAssertEqual(persisted.activeFilterID, refused ? "f1" : "f2")
        }
    }

    func testOutcomeRawValuesRemainStableForPersistedDiagnostics() {
        XCTAssertEqual(HeadlessFocusSwitchOutcome.committed.rawValue, "committed")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.deferred.rawValue, "deferred")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.alreadyActive.rawValue, "alreadyActive")
        XCTAssertEqual(HeadlessFocusSwitchOutcome.disallowed.rawValue, "disallowed")
    }

    // Harness/seed/warm-artifact fixtures live in TestSupport/FocusSwitchEngineTestSupport.swift,
    // SHARED with BackgroundPendingSwitchDrainTests so both suites drive the identical warm-reuse path.

    // MARK: - Gate (fail-closed security boundary)

    /// 🔴 THE CONSENT GATE FAILS CLOSED when the configuration cannot be read.
    ///
    /// `loadState` folds an unreadable or undecodable configuration into `didReseed` and hands back
    /// a DEFAULT `AppConfiguration()`, whose `keepNetworkActivity` is `true`. Reading that flag
    /// alone turns "we could not tell" into "consent granted" — the one direction a consent gate
    /// must never fail (Codex, PR #625). This file already refuses to COMMIT a switch on the same
    /// signal; a diagnostic write gets no weaker rule.
    ///
    /// The library IS seeded and the configuration is NOT, so the only thing wrong is the config
    /// read — the same shape as a transient file error, not a broken harness.
    func testAnUnreadableConfigurationWritesNoDiagnostic() async {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(
            outcome, .disallowed,
            "an unreadable configuration must refuse the switch — the pre-existing rule")
        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: h.defaults),
            "consent could not be established, so nothing may be written — a default "
                + "AppConfiguration reads keepNetworkActivity as true and would fail OPEN")
    }

    func testExtensionFirstUnknownCredentialRefusesSwitchWithoutChangingActiveFilter() async throws {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: false)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        try FileManager.default.removeItem(at: SecurityProtectedSurfaceStorage.projectionURL(containerURL: h.dir))
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
        XCTAssertEqual(outcome, .disallowed)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults))
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1")
    }

    func testFreeUserIsAllowedToSwitch() async {
        // Focus auto-switch is available to ALL tiers — the Plus paywall was dropped. A free user's switch
        // is NOT gated out: with no warm artifact it simply defers to the foreground reconcile (records the
        // marker + nudges), exactly like a Plus user would.
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: false)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

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
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults,
            projectionURL: SecurityProtectedSurfaceStorage.projectionURL(containerURL: h.dir))

        _ = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        let diag = FocusSwitchDiagnostics.last(in: h.defaults)
        XCTAssertEqual(diag?.outcome, "disallowed")
        XCTAssertEqual(diag?.reason, "disallowed-auth-to-edit")
    }

    func testAuthToEditIsDisallowedAndRecordsNothing() async {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults,
            projectionURL: SecurityProtectedSurfaceStorage.projectionURL(containerURL: h.dir))

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
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .disallowed, "A missing/corrupt configuration must fail closed, not switch from defaults.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "A fail-closed load must not record a marker.")
        XCTAssertTrue(h.spy.posted.isEmpty)
    }

    func testMissingTargetIsDisallowed() async {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "ghost", env: h.env)

        XCTAssertEqual(outcome, .disallowed)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults))
    }

    // MARK: - Reseed guard

    func testReseedFromMissingLibraryIsDisallowed() async {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true) // Plus passes the gate; the missing library forces a reseed.
        // No filter-library.json written ⇒ loadState reseeds the defaults (didReseed == true).

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "filter-balanced", env: h.env)

        XCTAssertEqual(outcome, .disallowed, "A reseeded (un-persisted) library must refuse — never write defaults over real state.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "The reseed guard precedes the marker record.")
    }

    // MARK: - Already active

    func testAlreadyActiveRecordsMarkerAndNudges() async {
        let now = Date(timeIntervalSinceReferenceDate: 55_000)
        let h = makeFocusSwitchEngineHarness(now: now); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

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
        let h = makeFocusSwitchEngineHarness(now: now); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2", "f3"])
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

    func testContendedPublicationDefersWithoutAdvancingTheSavedSelection() async throws {
        let validated = DispatchSemaphore(value: 0)
        let ready = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let h = makeFocusSwitchEngineHarness(onHeadlessValidationCompleted: { validated.signal() })
        defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let publicationLock = h.env.publishLockURL
        let configurationURL = h.env.configurationURL
        let before = try Data(contentsOf: configurationURL)
        let observation = FocusBlockedPublicationObservation()
        // A different publisher owns the lock while this intent validates a warm
        // target. The old engine writes the new selection, then blocks behind it.
        DispatchQueue.global().async {
            FilterPublishLock.withExclusiveLock(at: publicationLock) {
                ready.signal()
                let first = validated.wait(timeout: .now() + 10) == .success
                let second = validated.wait(timeout: .now() + 10) == .success
                let deadline = Date().addingTimeInterval(2)
                var unchanged = true
                while Date() < deadline {
                    if (try? Data(contentsOf: configurationURL)) != before { unchanged = false; break }
                    Thread.sleep(forTimeInterval: 0.005)
                }
                observation.record(validated: first && second, unchanged: unchanged)
            }
            finished.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(observation.value.validated, "Both warm validations must have executed.")
        XCTAssertTrue(observation.value.unchanged, "A blocked publisher must leave the prior usable selection intact.")
        XCTAssertEqual(outcome, .deferred, "An intent must not wait indefinitely behind another publisher.")
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "deferred-publication-contended")
        XCTAssertEqual(try Data(contentsOf: configurationURL), before)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")
    }

    func testContendedConfigurationReturnsBeforeTheWriterReleasesItsLock() async throws {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let configurationLock = h.env.configurationWriteLockURL
        let before = try Data(contentsOf: h.env.configurationURL)
        let observation = FocusBlockedPublicationObservation()
        DispatchQueue.global().async {
            FilterPublishLock.withExclusiveLock(at: configurationLock) {
                ready.signal()
                // The intent must complete while another process still owns the write lock;
                // even its optional diagnostic write must not wait for that process.
                observation.record(validated: release.wait(timeout: .now() + 5) == .success, unchanged: true)
            }
            finished.signal()
        }
        XCTAssertEqual(ready.wait(timeout: .now() + 5), .success)
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertTrue(observation.value.validated, "The intent waited behind a configuration writer.")
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(try Data(contentsOf: h.env.configurationURL), before)
        XCTAssertNil(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer())
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")
    }

    func testCancelledPublicationKeepsThePreviousSelectionAndPendingRequest() async throws {
        try await Task {
            let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
            let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
            try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
            let before = try Data(contentsOf: h.env.configurationURL)
            withUnsafeCurrentTask { $0?.cancel() }
            let result = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
            XCTAssertEqual(result, .deferred)
            XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "deferred-publication-cancelled")
            XCTAssertEqual(try Data(contentsOf: h.env.configurationURL), before)
            XCTAssertNil(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer())
            XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")
        }.value
    }

    func testCatalogVetoAtPublicationDoesNotRewriteTheSavedPair() async throws {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let beforeConfiguration = try Data(contentsOf: h.env.configurationURL)
        let beforeLibrary = try Data(contentsOf: h.env.filterLibraryURL)
        let request = PendingFilterSwitchRequest(targetFilterID: "f2", requestedAt: h.env.now())
        PendingFilterSwitchStore.record(request, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
        let catalogURL = h.env.catalogCacheURL.appendingPathComponent("catalog/latest.json")
        let env = h.env.forReplay(now: { request.requestedAt }, supersededVeto: {
            // Simulate a catalog change after off-lock validation, at the final veto boundary.
            try? FileManager.default.removeItem(at: catalogURL)
            return false
        }, expectedMarker: request)
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: env)
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(try Data(contentsOf: h.env.configurationURL), beforeConfiguration)
        XCTAssertEqual(try Data(contentsOf: h.env.filterLibraryURL), beforeLibrary)
        XCTAssertNil(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer())
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "deferred-catalog-moved-inlock")
    }

    func testPointerWriteFailureRollsBackThePairThatThisCommitWrote() async throws {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let request = PendingFilterSwitchRequest(targetFilterID: "f2", requestedAt: h.env.now())
        PendingFilterSwitchStore.record(request, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
        let pointerURL = FilterArtifactStore(directoryURL: h.dir).artifactPointerURL()
        let env = h.env.forReplay(now: { request.requestedAt }, supersededVeto: {
            // A directory at the pointer's file path forces the real atomic write to fail.
            try? FileManager.default.createDirectory(at: pointerURL, withIntermediateDirectories: true)
            return false
        }, expectedMarker: request)
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: env)
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: h.env.configurationURL))
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(library.activeFilterID, "f1")
        XCTAssertTrue(config.enabledBlocklistIDs.isEmpty)
        XCTAssertEqual(config.configurationGeneration, 3, "Initial 1 → attempted commit 2 → fenced rollback 3.")
        XCTAssertEqual(library.configurationGeneration, config.configurationGeneration)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults), request)
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "deferred-commit-failed")
    }

    func testNewerConfigurationAfterValidationWinsWithoutRollback() async throws {
        let mutation = FocusValidationMutation()
        let h = makeFocusSwitchEngineHarness(onHeadlessValidationCompleted: { mutation.validationCompleted() })
        defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        var newer = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: h.env.configurationURL))
        newer.keepNetworkActivity = false
        let newerConfiguration = newer
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        let configurationURL = h.env.configurationURL
        let libraryURL = h.env.filterLibraryURL
        let lockURL = h.env.configurationWriteLockURL
        mutation.configure {
            _ = try? SharedFilterStatePersistence.writeConfigurationAndLibrary(
                configuration: newerConfiguration, library: library,
                configurationURL: configurationURL, filterLibraryURL: libraryURL,
                crossProcessLockURL: lockURL)
        }
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)
        let actual = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: configurationURL))
        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(actual.configurationGeneration, 2)
        XCTAssertFalse(actual.keepNetworkActivity)
        XCTAssertTrue(actual.enabledBlocklistIDs.isEmpty)
        XCTAssertNil(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer())
        XCTAssertNil(FocusSwitchDiagnostics.last(in: h.defaults), "The newer privacy setting must also govern the diagnostic.")
    }

    func testCommittedWarmFlipPublishesTargetAndLeavesMarker() async throws {
        let now = Date(timeIntervalSinceReferenceDate: 90_000)
        let h = makeFocusSwitchEngineHarness(now: now); defer { cleanupFocusSwitchHarness(h) }
        // catalogCacheURL must be where the fixture wrote the catalog; reuse the harness dir's cache path.
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .committed, "A warm target with the app inactive must commit immediately.")
        // On-disk library now selects the target and the artifact pointer flipped to the staged token.
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f2", "The committed switch must make the target active on disk.")
        let config = try JSONDecoder().decode(AppConfiguration.self, from: Data(contentsOf: h.env.configurationURL))
        XCTAssertGreaterThan(config.configurationGeneration, 1, "The commit must bump the configuration generation.")
        let pointerToken = FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer()?.token
        XCTAssertEqual(pointerToken, staged.token, "The artifact pointer must flip to the validated warm token.")
        // The marker is LEFT for the foreground reconcile (the ENGINE never clears it; the BGTask
        // drain clears only the moot gate-closed/superseded cases before ever driving the engine).
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

    func testCommittedDecisionIsWatermarkedBeforeDelayedOutcomeNotification() async throws {
        // The outcome callback is allowed to suspend after the engine has decided. A clear during
        // that suspension must still hide the decision when the consent-gated record finally lands.
        let decisionAt = Date(timeIntervalSinceReferenceDate: 91_000)
        let clearedAt = decisionAt.addingTimeInterval(1)
        let clearProbe = FocusDiagnosticClearProbe(clearedAt: clearedAt, decisionAt: decisionAt)
        let h = makeFocusSwitchEngineHarness(
            now: Date(timeIntervalSinceReferenceDate: 90_000),
            diagnosticNow: { clearProbe.now() },
            notifySwitchOutcome: { _, _ in clearProbe.clear() })
        defer { cleanupFocusSwitchHarness(h) }
        clearProbe.install(
            defaults: h.defaults, orderingLockURL: h.env.focusDiagnosticOrderingLockURL)
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .committed)
        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: h.defaults),
            "a clear during post-decision notification must hide the delayed diagnostic write")
    }

    func testCommittedDiagnosticCapturesTheEventBeforeTheCommitContinuation() async throws {
        // The publish operation can finish before the headless task resumes after its async boundary.
        // A clear in that gap must not turn the already-committed decision into a post-clear record.
        let decisionAt = Date(timeIntervalSinceReferenceDate: 93_000)
        let clearedAt = decisionAt.addingTimeInterval(1)
        let clearProbe = FocusDiagnosticClearProbe(clearedAt: clearedAt, decisionAt: decisionAt)
        let h = makeFocusSwitchEngineHarness(
            now: Date(timeIntervalSinceReferenceDate: 92_000),
            diagnosticNow: { clearProbe.now() },
            onHeadlessCommitCompleted: { clearProbe.clear() })
        defer { cleanupFocusSwitchHarness(h) }
        clearProbe.install(
            defaults: h.defaults, orderingLockURL: h.env.focusDiagnosticOrderingLockURL)
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .committed)
        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: h.defaults),
            "a clear after commit but before the caller continuation must hide the pre-clear event")
    }

    func testDeferredDiagnosticCapturesTheEventBeforeValidationContinuation() async throws {
        // A failed warm lookup can determine the deferred outcome before its async caller resumes.
        // The event captured at that completion boundary must remain pre-clear when a clear lands in
        // the completion-to-continuation gap.
        let decisionAt = Date(timeIntervalSinceReferenceDate: 95_000)
        let clearedAt = decisionAt.addingTimeInterval(1)
        let clearProbe = FocusDiagnosticClearProbe(clearedAt: clearedAt, decisionAt: decisionAt)
        let h = makeFocusSwitchEngineHarness(
            now: Date(timeIntervalSinceReferenceDate: 94_000),
            diagnosticNow: { clearProbe.now() },
            onHeadlessValidationCompleted: { clearProbe.clear() })
        defer { cleanupFocusSwitchHarness(h) }
        clearProbe.install(
            defaults: h.defaults, orderingLockURL: h.env.focusDiagnosticOrderingLockURL)

        // A bogus target token forces the warm lookup through its detached validation task and then
        // into the deferred branch; there is no catalog cache to make it reusable.
        var library = FilterLibrary(
            filters: [
                Filter(id: "f1", name: "F1", enabledBlocklistIDs: []),
                Filter(id: "f2", name: "F2", enabledBlocklistIDs: [], lastCompiledToken: "missing-token")
            ],
            activeFilterID: "f1"
        )
        library.configurationGeneration = 1
        try JSONEncoder().encode(library).write(to: h.env.filterLibraryURL)
        var configuration = AppConfiguration(enabledBlocklistIDs: [], configurationGeneration: 1)
        configuration.isPaid = true
        try JSONEncoder().encode(configuration).write(to: h.env.configurationURL)

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: h.defaults),
            "a clear after warm validation but before the deferred caller continuation must hide the pre-clear event")
    }

    func testInLockReplaySupersededVetoLeavesTheSavedPairUntouched() async throws {
        // The replay-only in-lock supersession veto (Codex PR #410 P1): a warm, otherwise-committable
        // switch whose veto reports "superseded at flip time" must abort before writing — the
        // on-disk selection stays on the pre-switch filter (the user's manual choice), the pointer
        // never flips, and the diagnostic names the replay-superseded reason.
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        // Realistic replay state: the drain always holds marker == expected at read time (a mismatch
        // would abort earlier, at the compare-and-record — covered by its own test below).
        let replayed = PendingFilterSwitchRequest(
            targetFilterID: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 9_000)
        )
        PendingFilterSwitchStore.record(replayed, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
        let vetoEnv = h.env.forReplay(
            now: { replayed.requestedAt },
            supersededVeto: { true },
            expectedMarker: replayed
        )

        let beforeConfiguration = try Data(contentsOf: h.env.configurationURL)
        let beforeLibrary = try Data(contentsOf: h.env.filterLibraryURL)
        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: vetoEnv)
        XCTAssertEqual(try Data(contentsOf: h.env.configurationURL), beforeConfiguration)
        XCTAssertEqual(try Data(contentsOf: h.env.filterLibraryURL), beforeLibrary)

        XCTAssertEqual(outcome, .deferred, "The in-lock replay veto must abort the commit as a clean defer.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1",
                       "The veto must preserve the pre-switch (manual) selection on disk.")
        XCTAssertNil(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer()?.token,
                     "The artifact pointer must never flip on a vetoed replay.")
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "deferred-replay-superseded-inlock",
                       "The diagnostic must name the replay-superseded veto so the abort is diagnosable on Release.")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults), replayed,
                       "The veto must not touch the marker — the next reconcile's supersession check owns the drop.")
    }

    func testReplayMarkerChangedAbortsFailClosedAndPreservesNewerMarker() async throws {
        // The compare-and-record seam (lavasec-ios public review of the PR #410 promotion): a NEWER
        // intent won the marker slot while the replay was flock-blocked. The replay's main-path
        // record must MISMATCH and abort fail-closed — never re-stamp the old request over the
        // newer one — leaving the newer marker for the next drain pass, with its own reason.
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        // Active deliberately ≠ target so the engine takes the MAIN switch path: this test covers
        // only that path's compare-and-record; the already-active branch's best-effort record
        // yields silently by design and is not asserted here.
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2", "f3"])
        let replayed = PendingFilterSwitchRequest(
            targetFilterID: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 5_000)
        )
        // The newer intent's marker is what's on disk by the time the replay drives the engine.
        let newer = PendingFilterSwitchRequest(
            targetFilterID: "f3", requestedAt: Date(timeIntervalSinceReferenceDate: 6_000)
        )
        PendingFilterSwitchStore.record(newer, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
        let replayEnv = h.env.forReplay(
            now: { replayed.requestedAt },
            supersededVeto: { false },
            expectedMarker: replayed
        )

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: replayEnv)

        XCTAssertEqual(outcome, .disallowed, "A replay whose marker was superseded must abort fail-closed.")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults), newer,
                       "The newer intent's marker must survive the aborted replay.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1", "An aborted replay must not change the on-disk selection.")
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.reason, "disallowed-replay-marker-changed",
                       "The abort must record its distinct Release-diagnosable reason.")
        XCTAssertTrue(h.spy.posted.isEmpty, "The record-abort path posts no nudge (nothing changed).")
    }

    func testReplayMatchingMarkerCommitsWarmTarget() async throws {
        // The seam must not get in a legitimate replay's way: marker unchanged since the drain read
        // it ⇒ compare-and-record accepts and the warm commit proceeds exactly as before.
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let replayed = PendingFilterSwitchRequest(
            targetFilterID: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 9_000)
        )
        PendingFilterSwitchStore.record(replayed, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
        let replayEnv = h.env.forReplay(
            now: { replayed.requestedAt },
            supersededVeto: { false },
            expectedMarker: replayed
        )

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: replayEnv)

        XCTAssertEqual(outcome, .committed, "An unchanged marker must let the replay's warm commit proceed.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f2")
        XCTAssertEqual(FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer()?.token, staged.token,
                       "The committed warm replay must flip the artifact pointer to the staged token (parity with the non-replay committed test).")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults), replayed,
                       "The committed replay leaves the marker (foreground protocol) with its ORIGINAL identity.")
    }

    func testStaleCachedCatalogDefersInsteadOfFlipping() async throws {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        // Make the cached catalog STALE on disk (freshness is the latest.json mtime, well past the env's
        // 7-day window) so the warm-reuse gate rejects it and the headless path defers (cold-compile on the
        // foreground) rather than flip a stale basis.
        let latestURL = h.env.catalogCacheURL.appendingPathComponent("catalog/latest.json")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: latestURL.path)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred, "A stale cached catalog must defer (cold-compile on the foreground), not warm-flip.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1", "A deferral must not change the on-disk active filter.")
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2")
    }

    func testNoWarmArtifactDefersAndKeepsMarker() async {
        let h = makeFocusSwitchEngineHarness(); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        // App is NOT foreground-active and there is no staged warm artifact / fresh cached catalog,
        // so the headless path defers (it never cold-compiles inline).

        let outcome = await HeadlessFocusFilterSwitchEngine.performSwitch(toFilterID: "f2", env: h.env)

        XCTAssertEqual(outcome, .deferred)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults)?.targetFilterID, "f2",
                       "The durable marker is the correctness guarantee even when the immediate commit is skipped.")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName])
    }
}

private final class FocusBlockedPublicationObservation: @unchecked Sendable {
    private let lock = NSLock()
    private var result = (validated: false, unchanged: false)
    func record(validated: Bool, unchanged: Bool) {
        lock.lock(); defer { lock.unlock() }
        result = (validated, unchanged)
    }
    var value: (validated: Bool, unchanged: Bool) {
        lock.lock(); defer { lock.unlock() }
        return result
    }
}

private final class FocusValidationMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var action: (@Sendable () -> Void)?

    func configure(_ action: @escaping @Sendable () -> Void) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    func validationCompleted() {
        lock.lock()
        count += 1
        let mutation = count == 2 ? action : nil
        lock.unlock()
        mutation?()
    }
}
