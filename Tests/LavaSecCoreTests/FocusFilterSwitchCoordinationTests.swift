import XCTest
@testable import LavaSecCore

final class FocusFilterSwitchCoordinationTests: XCTestCase {
    private func makeDefaults() -> UserDefaults {
        let suite = "focus-switch-\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    // MARK: - FocusSwitchDiagnostics

    func testFocusSwitchDiagnosticRoundTripsAndDefaultsNil() {
        let defaults = makeDefaults()
        XCTAssertNil(FocusSwitchDiagnostics.last(in: defaults))
        let record = FocusSwitchDiagnosticRecord(
            outcome: "committed", targetFilterID: "filter-extra", at: Date(timeIntervalSinceReferenceDate: 4_242)
        )
        FocusSwitchDiagnostics.record(record, in: defaults)
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: defaults), record)
    }

    func testFocusSwitchDiagnosticOverwritesWithLatest() {
        let defaults = makeDefaults()
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(outcome: "deferred", targetFilterID: "a", at: Date(timeIntervalSinceReferenceDate: 1)),
            in: defaults
        )
        let latest = FocusSwitchDiagnosticRecord(outcome: "committed", targetFilterID: "b", at: Date(timeIntervalSinceReferenceDate: 2))
        FocusSwitchDiagnostics.record(latest, in: defaults)
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: defaults), latest)
    }

    /// Backward compatibility across an app upgrade: a diagnostic record persisted by an OLDER build (before
    /// the `reason` field existed) has NO `reason` key. `FocusSwitchDiagnosticRecord.init(from:)` must still
    /// decode it (reason: "") rather than throwing — otherwise the first launch after upgrade would silently
    /// drop the last-switch diagnostic (the exact closed-app signal this record exists to carry). Feed a raw
    /// reason-less payload — built the way the old build's encoder ([.sortedKeys], default Date→Double) wrote
    /// it — straight through the store. Guards a regression from `decodeIfPresent` back to a plain `decode`,
    /// which the round-trip tests above cannot catch (the encoder always emits the key).
    func testFocusSwitchDiagnosticDecodesLegacyRecordWithoutReasonKey() throws {
        let defaults = makeDefaults()
        let legacyJSON = #"{"at":4242,"outcome":"committed","targetFilterID":"filter-extra"}"#
        defaults.set(Data(legacyJSON.utf8), forKey: FocusSwitchDiagnostics.defaultsKey)

        let decoded = try XCTUnwrap(
            FocusSwitchDiagnostics.last(in: defaults),
            "A pre-`reason` record must still decode after an app upgrade, not be dropped."
        )
        XCTAssertEqual(decoded.outcome, "committed")
        XCTAssertEqual(decoded.targetFilterID, "filter-extra")
        XCTAssertEqual(decoded.at, Date(timeIntervalSinceReferenceDate: 4242))
        XCTAssertEqual(decoded.reason, "", "A missing `reason` key must default to empty, not fail the decode.")
    }

    // MARK: - PendingFilterSwitchStore

    func testRecordAndReadRoundTrips() {
        let defaults = makeDefaults()
        let now = Date(timeIntervalSinceReferenceDate: 1000)
        let request = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: now)

        XCTAssertNil(PendingFilterSwitchStore.current(in: defaults))
        PendingFilterSwitchStore.record(request, in: defaults)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: defaults), request)
    }

    func testRecordOverwritesWithNewestRequest() {
        let defaults = makeDefaults()
        let first = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: Date(timeIntervalSinceReferenceDate: 1))
        let second = PendingFilterSwitchRequest(targetFilterID: "sleep", requestedAt: Date(timeIntervalSinceReferenceDate: 2))

        PendingFilterSwitchStore.record(first, in: defaults)
        PendingFilterSwitchStore.record(second, in: defaults)
        XCTAssertEqual(PendingFilterSwitchStore.current(in: defaults), second)
    }

    func testClearIfMatchesClearsExactRequest() {
        let defaults = makeDefaults()
        let request = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: Date(timeIntervalSinceReferenceDate: 1))
        PendingFilterSwitchStore.record(request, in: defaults)

        XCTAssertTrue(PendingFilterSwitchStore.clearIfMatches(request, in: defaults))
        XCTAssertNil(PendingFilterSwitchStore.current(in: defaults))
    }

    func testClearIfMatchesPreservesANewerRequest() {
        let defaults = makeDefaults()
        let reconciled = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: Date(timeIntervalSinceReferenceDate: 1))
        let newer = PendingFilterSwitchRequest(targetFilterID: "sleep", requestedAt: Date(timeIntervalSinceReferenceDate: 2))
        // Foreground read `reconciled`, applied it; a newer Focus switch landed before the clear.
        PendingFilterSwitchStore.record(newer, in: defaults)

        XCTAssertFalse(PendingFilterSwitchStore.clearIfMatches(reconciled, in: defaults))
        XCTAssertEqual(PendingFilterSwitchStore.current(in: defaults), newer, "A newer pending request must survive a stale clear.")
    }

    func testLastForegroundSwitchRoundTripsAndDefaultsNil() {
        let defaults = makeDefaults()
        XCTAssertNil(PendingFilterSwitchStore.lastForegroundSwitch(in: defaults))
        let now = Date(timeIntervalSinceReferenceDate: 0) // reference date — must read back, not be a 0.0 sentinel
        PendingFilterSwitchStore.recordForegroundSwitch(at: now, in: defaults)
        XCTAssertEqual(PendingFilterSwitchStore.lastForegroundSwitch(in: defaults), now)
    }

    func testManualSwitchAfterRequestSupersedesIt() {
        // The reconcile drops a marker whose requestedAt is at-or-before the last foreground switch.
        let defaults = makeDefaults()
        let request = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: Date(timeIntervalSinceReferenceDate: 100))
        // Manual switch happened AFTER the request ⇒ request is stale.
        PendingFilterSwitchStore.recordForegroundSwitch(at: Date(timeIntervalSinceReferenceDate: 200), in: defaults)
        let last = PendingFilterSwitchStore.lastForegroundSwitch(in: defaults)
        XCTAssertNotNil(last)
        XCTAssertLessThanOrEqual(request.requestedAt, last!, "A request older than the last manual switch must be treated as superseded.")
        // A request NEWER than the last foreground switch is NOT superseded.
        let newer = PendingFilterSwitchRequest(targetFilterID: "sleep", requestedAt: Date(timeIntervalSinceReferenceDate: 300))
        XCTAssertGreaterThan(newer.requestedAt, last!)
    }

    /// Exact-tie policy (founder review P2-3): the reconcile uses `requestedAt <= lastForegroundSwitchAt`, so an
    /// identical instant FAVORS the manual switch (the request is dropped as superseded). This guards the
    /// timestamp round-trip precision the tie-break relies on: if `recordForegroundSwitch` / `lastForegroundSwitch`
    /// lost precision, an intended tie could read back as `>` and silently flip the policy. The app-level `<=`
    /// drop is pinned at the source level in FocusFilterSwitchWiringSourceTests.
    func testExactTimestampTieFavorsManualSwitch() {
        let defaults = makeDefaults()
        let instant = Date(timeIntervalSinceReferenceDate: 100)
        let request = PendingFilterSwitchRequest(targetFilterID: "work", requestedAt: instant)
        PendingFilterSwitchStore.recordForegroundSwitch(at: instant, in: defaults)
        let last = try? XCTUnwrap(PendingFilterSwitchStore.lastForegroundSwitch(in: defaults))
        XCTAssertEqual(last, instant, "The foreground-switch instant must round-trip EXACTLY so an intended tie stays a tie.")
        // The reconcile's drop condition (`requestedAt <= last`) holds on the tie ⇒ the manual switch wins.
        XCTAssertLessThanOrEqual(request.requestedAt, last!, "On an exact tie the request is at-or-before the manual switch, so it is dropped (manual wins).")
    }

    // (AppForegroundActivityState tests removed 2026-06-29 — the type is gone; the headless switch is
    // state-agnostic, relying on the cross-process CAS instead of a foreground-active flag.)
}
