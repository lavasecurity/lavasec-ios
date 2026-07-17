import XCTest
@testable import LavaSecCore
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

/// Unit coverage for the background pending-switch drain (`BackgroundPendingSwitchDrain`) — the
/// BGTask-side twin of the foreground reconcile's moot-marker handling. Two load-bearing properties:
/// ORDERING (the auth-gate and manual-switch supersession checks run BEFORE the engine, because the
/// engine re-records the marker and a late drop would lose the user's newer manual switch) and
/// REPLAY IDENTITY (the engine is driven with `now` overridden to the ORIGINAL `requestedAt`, so a
/// replayed marker can never out-rank a manual switch made after the original automation fired).
/// Harness/seed/warm-artifact fixtures are SHARED with `HeadlessFocusFilterSwitchEngineTests`
/// (TestSupport/FocusSwitchEngineTestSupport.swift) so both suites drive the identical warm-reuse path.
final class BackgroundPendingSwitchDrainTests: XCTestCase {
    private func recordMarker(
        _ harness: FocusSwitchEngineHarness, target: String, requestedAt: Date
    ) -> PendingFilterSwitchRequest {
        let request = PendingFilterSwitchRequest(targetFilterID: target, requestedAt: requestedAt)
        PendingFilterSwitchStore.record(request, in: harness.defaults, lockURL: harness.env.pendingMarkerLockURL)
        return request
    }

    // MARK: - No marker

    func testNoMarkerIsANoOp() async {
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd"); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .noMarker)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "A no-op drain must not create a marker.")
        XCTAssertTrue(h.spy.posted.isEmpty, "A no-op drain must not nudge the foreground.")
    }

    // MARK: - Moot markers cleared WITHOUT driving the engine

    func testAuthGateClosedClearsMarkerWithoutDrivingEngine() async throws {
        // Same invariant as the foreground reconcile's gate-closed branch: a marker recorded while
        // editing was unprotected must NOT apply once filter editing became auth-protected — not
        // now, not on a later pass — so the drain clears it and never reaches the engine.
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd"); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        _ = recordMarker(h, target: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 5_000))
        SecurityProtectedSurfaceStorage.saveProtectedSurfaces([.filterEditing], to: h.defaults)

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .clearedAuthGateClosed)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults), "The moot marker must be cleared.")
        XCTAssertTrue(h.spy.posted.isEmpty, "The engine must not be driven (no nudge) on a gate-closed clear.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1", "A gate-closed clear must not change the on-disk active filter.")
    }

    func testSupersededMarkerIsClearedWithoutDrivingEngine() async throws {
        // CORRECTNESS-CRITICAL ordering: the engine re-records the marker, so a superseded marker
        // MUST be dropped before the engine runs — otherwise the drained automation would resurrect
        // and beat the user's newer manual switch (a lost update).
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd"); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        _ = recordMarker(h, target: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 5_000))
        // The manual switch was INITIATED after the automation's request → the user wins.
        PendingFilterSwitchStore.recordForegroundSwitch(
            at: Date(timeIntervalSinceReferenceDate: 6_000), in: h.defaults
        )

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .clearedSuperseded)
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults),
                     "The superseded marker must be cleared, never re-recorded by the engine.")
        XCTAssertTrue(h.spy.posted.isEmpty, "The engine must not be driven for a superseded marker.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f1", "The user's manual choice must stand.")
    }

    func testExactTimestampTieFavorsTheManualSwitch() async {
        // The `<=` tie rule lives in the SHARED PendingFilterSwitchStore.isSupersededByForegroundSwitch;
        // this exercises it through the drain (the reconcile consumes the same predicate).
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd"); defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        let instant = Date(timeIntervalSinceReferenceDate: 5_000)
        _ = recordMarker(h, target: "f2", requestedAt: instant)
        PendingFilterSwitchStore.recordForegroundSwitch(at: instant, in: h.defaults)

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .clearedSuperseded, "An exact tie must favor the manual switch.")
        XCTAssertNil(PendingFilterSwitchStore.current(in: h.defaults))
    }

    // MARK: - Cancellation gate (BGTask expiry before the engine runs)

    func testCancelledTaskStopsBeforeTheEngineAndLeavesMarkerUntouched() async {
        // Deterministic: the detached task cancels ITSELF before the drain runs, so the drain's
        // pre-engine cancellation gate must return .cancelled — marker untouched, engine not driven.
        // (The harness is built inside the detached task: the engine Environment is deliberately
        // not Sendable and must stay on the task that consumes it.)
        let result = await Task.detached { () -> (BackgroundPendingSwitchDrain.Outcome, String?, Date?, [String]) in
            let h = makeFocusSwitchEngineHarness(prefix: "bpsd-cancel")
            defer { cleanupFocusSwitchHarness(h) }
            seedFocusSwitchConfiguration(h, isPaid: true)
            seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
            let request = PendingFilterSwitchRequest(
                targetFilterID: "f2", requestedAt: Date(timeIntervalSinceReferenceDate: 5_000)
            )
            PendingFilterSwitchStore.record(request, in: h.defaults, lockURL: h.env.pendingMarkerLockURL)
            withUnsafeCurrentTask { $0?.cancel() }
            let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)
            let marker = PendingFilterSwitchStore.current(in: h.defaults)
            return (outcome, marker?.targetFilterID, marker?.requestedAt, h.spy.posted)
        }.value

        XCTAssertEqual(result.0, .cancelled)
        XCTAssertEqual(result.1, "f2", "An expired-task drain must leave the marker for the next cycle.")
        XCTAssertEqual(result.2, Date(timeIntervalSinceReferenceDate: 5_000),
                       "An expired-task drain must not re-stamp the marker.")
        // Marker fields alone can't prove non-drive (a replay re-record writes IDENTICAL values —
        // replay identity); the spy is the discriminator the sibling moot-clear tests use.
        XCTAssertTrue(result.3.isEmpty, "The engine must not be driven after the cancellation gate fires.")
    }

    // MARK: - Live markers drive the shared engine (marker LEFT — foreground protocol unchanged)

    func testNewerMarkerRedefersOnWarmMissAndPreservesOriginalRequestedAt() async {
        // A marker strictly newer than the last manual switch is live. With no warm artifact the
        // engine re-defers; the durable marker survives — and REPLAY IDENTITY holds: the re-record
        // carries the ORIGINAL requestedAt (the drain overrides env.now), NOT drain time, so a
        // manual switch made between the original automation and a later reconcile still wins.
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd", now: Date(timeIntervalSinceReferenceDate: 10_000))
        defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        PendingFilterSwitchStore.recordForegroundSwitch(
            at: Date(timeIntervalSinceReferenceDate: 4_000), in: h.defaults
        )
        let original = Date(timeIntervalSinceReferenceDate: 5_000)
        _ = recordMarker(h, target: "f2", requestedAt: original)

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .drove(.deferred))
        let marker = PendingFilterSwitchStore.current(in: h.defaults)
        XCTAssertEqual(marker?.targetFilterID, "f2",
                       "A re-deferred marker must survive for the next cycle/foreground.")
        XCTAssertEqual(marker?.requestedAt, original,
                       "The replay must preserve the ORIGINAL requestedAt — a drain-time re-stamp would let a "
                       + "days-old automation out-rank a manual switch made after it (lost update).")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName],
                       "The engine's defer path nudges a resident foreground, exactly as an intent's would.")
    }

    func testAlreadyActiveReplayPreservesMarkerIdentityAndPostsNoBanner() async {
        // Target already active (a prior commit landed): the engine's already-active branch
        // re-records + nudges. Replay identity must hold here too — the marker keeps the ORIGINAL
        // requestedAt, so a daily drain of an already-applied marker never refreshes its precedence.
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd", now: Date(timeIntervalSinceReferenceDate: 10_000))
        defer { cleanupFocusSwitchHarness(h) }
        seedFocusSwitchConfiguration(h, isPaid: true)
        seedFocusSwitchLibrary(h, active: "f1", ids: ["f1", "f2"])
        let original = Date(timeIntervalSinceReferenceDate: 5_000)
        _ = recordMarker(h, target: "f1", requestedAt: original)

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .drove(.alreadyActive))
        XCTAssertEqual(PendingFilterSwitchStore.current(in: h.defaults),
                       PendingFilterSwitchRequest(targetFilterID: "f1", requestedAt: original),
                       "The already-active replay must re-record the marker with its ORIGINAL requestedAt.")
        XCTAssertEqual(h.spy.posted, [FocusFilterSwitchSignal.darwinNotificationName])
    }

    func testDrainCommitsAWarmTargetAndLeavesMarker() async throws {
        // The flagship scenario this drain exists for: a deferred automation switch whose target is
        // warm (fresh cached catalog + staged artifact) commits FROM THE BACKGROUND — no app open —
        // and the marker is LEFT for the foreground reconcile protocol, exactly like the extension.
        let now = Date(timeIntervalSinceReferenceDate: 90_000)
        let h = makeFocusSwitchEngineHarness(prefix: "bpsd", now: now); defer { cleanupFocusSwitchHarness(h) }
        let staged = try await stageFocusSwitchWarmArtifact(cacheDir: h.env.catalogCacheURL, containerDir: h.dir)
        try seedFocusSwitchLibraryWithWarmTarget(h, token: staged.token, targetEnabled: ["source-a"])
        let original = Date(timeIntervalSinceReferenceDate: 80_000)
        _ = recordMarker(h, target: "f2", requestedAt: original)

        let outcome = await BackgroundPendingSwitchDrain.drain(env: h.env)

        XCTAssertEqual(outcome, .drove(.committed), "A warm target must commit from the background drain.")
        let library = try JSONDecoder().decode(FilterLibrary.self, from: Data(contentsOf: h.env.filterLibraryURL))
        XCTAssertEqual(library.activeFilterID, "f2", "The drained switch must make the target active on disk.")
        let pointerToken = FilterArtifactStore(directoryURL: h.dir).loadArtifactPointer()?.token
        XCTAssertEqual(pointerToken, staged.token, "The artifact pointer must flip to the validated warm token.")
        let marker = PendingFilterSwitchStore.current(in: h.defaults)
        XCTAssertEqual(marker?.targetFilterID, "f2",
                       "A committed drain must leave the marker for the foreground reconcile (re-sync protocol).")
        XCTAssertEqual(marker?.requestedAt, original,
                       "The committed replay's marker must keep the ORIGINAL requestedAt (replay identity).")
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: h.defaults)?.outcome, "committed")
    }
}
