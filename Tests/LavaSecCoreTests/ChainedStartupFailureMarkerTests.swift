import XCTest
@testable import LavaSecKit

final class ChainedStartupFailureMarkerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "ChainedStartupFailureMarkerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testRecordAndClearRoundTrip() {
        XCTAssertFalse(ChainedStartupFailureMarker.isMarked(in: defaults))

        ChainedStartupFailureMarker.record(reason: "chained-surrendered:budget-exhausted", in: defaults)

        XCTAssertTrue(ChainedStartupFailureMarker.isMarked(in: defaults))
        XCTAssertEqual(
            ChainedStartupFailureMarker.reason(in: defaults),
            "chained-surrendered:budget-exhausted")

        ChainedStartupFailureMarker.clear(in: defaults)

        XCTAssertFalse(ChainedStartupFailureMarker.isMarked(in: defaults))
        XCTAssertNil(ChainedStartupFailureMarker.reason(in: defaults))
    }

    func testEmptyReasonStillCreatesAnUnambiguousMarker() {
        ChainedStartupFailureMarker.record(reason: "", in: defaults)

        XCTAssertEqual(ChainedStartupFailureMarker.reason(in: defaults), "unknown")
    }

    func testExplicitRetryAdvancesGenerationAndRejectsRetiredProviderWrites() {
        XCTAssertEqual(ChainedStartupFailureMarker.currentGeneration(in: defaults), 0)
        XCTAssertTrue(
            ChainedStartupFailureMarker.record(
                reason: "chained-surrendered:budget-exhausted",
                generation: 0,
                in: defaults))

        let retryGeneration = ChainedStartupFailureMarker.beginExplicitRetry(in: defaults)
        XCTAssertEqual(retryGeneration, 1)
        XCTAssertNil(ChainedStartupFailureMarker.reason(in: defaults))
        XCTAssertTrue(
            ChainedStartupFailureMarker.state(in: defaults).explicitRetryRequested)

        XCTAssertFalse(
            ChainedStartupFailureMarker.record(
                reason: "stale-provider",
                generation: 0,
                in: defaults))
        XCTAssertNil(ChainedStartupFailureMarker.reason(in: defaults))
        XCTAssertTrue(
            ChainedStartupFailureMarker.record(
                reason: "current-provider",
                generation: retryGeneration,
                in: defaults))
        XCTAssertFalse(
            ChainedStartupFailureMarker.state(in: defaults).explicitRetryRequested)
        XCTAssertEqual(ChainedStartupFailureMarker.reason(in: defaults), "current-provider")

        XCTAssertFalse(
            ChainedStartupFailureMarker.clear(generation: 0, in: defaults))
        XCTAssertTrue(ChainedStartupFailureMarker.isMarked(in: defaults))
        XCTAssertTrue(
            ChainedStartupFailureMarker.clear(generation: retryGeneration, in: defaults))
        XCTAssertFalse(ChainedStartupFailureMarker.isMarked(in: defaults))
    }

    func testFileBackedMarkerPersistsTheGenerationAndReasonAtomically() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")

        XCTAssertEqual(
            try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL),
            .init(reason: nil, generation: 0))
        XCTAssertTrue(
            try ChainedStartupFailureMarker.record(
                reason: "chained-surrendered:budget-exhausted",
                generation: 0,
                storageURL: markerURL,
                lockURL: lockURL))
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path))
        XCTAssertEqual(
            try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL).reason,
            "chained-surrendered:budget-exhausted")

        let retryGeneration = try ChainedStartupFailureMarker.beginExplicitRetry(
            storageURL: markerURL,
            lockURL: lockURL)
        XCTAssertEqual(retryGeneration, 1)
        XCTAssertEqual(
            try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL),
            .init(reason: nil, generation: 1, explicitRetryRequested: true))

        XCTAssertTrue(
            try ChainedStartupFailureMarker.consumeExplicitRetryRequest(
                generation: retryGeneration,
                storageURL: markerURL,
                lockURL: lockURL))
        XCTAssertFalse(
            try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL)
                .explicitRetryRequested)

        XCTAssertFalse(
            try ChainedStartupFailureMarker.record(
                reason: "stale-provider",
                generation: 0,
                storageURL: markerURL,
                lockURL: lockURL))
        XCTAssertTrue(
            try ChainedStartupFailureMarker.record(
                reason: "current-provider",
                generation: retryGeneration,
                storageURL: markerURL,
                lockURL: lockURL))
        XCTAssertTrue(
            try ChainedStartupFailureMarker.clear(
                generation: retryGeneration,
                storageURL: markerURL,
                lockURL: lockURL))
        XCTAssertEqual(
            try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL),
            .init(reason: nil, generation: retryGeneration))
    }

    func testExplicitRetryRepairsCorruptFileWithFreshGeneration() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")
        try Data("not-json".utf8).write(to: markerURL)

        let retryGeneration = try ChainedStartupFailureMarker.beginExplicitRetry(
            storageURL: markerURL,
            lockURL: lockURL)
        let state = try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL)
        XCTAssertNotEqual(retryGeneration, 0)
        XCTAssertEqual(state.generation, retryGeneration)
        XCTAssertNil(state.reason)
        XCTAssertTrue(state.explicitRetryRequested)
    }

    /// A corrupt marker must not be able to suppress the terminal gate.
    ///
    /// `beginExplicitRetry` already repaired corruption; terminal publication did not, so a torn
    /// file meant the provider could never establish the gate — and an armed Connect-On-Demand
    /// profile would relaunch a failing provider forever, unrecoverable while the app is
    /// suspended. That is the exact loop this type exists to stop (Codex, PR #636).
    func testATerminalRefusalRepairsACorruptMarker() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")
        try Data("not-json".utf8).write(to: markerURL)

        let recorded = try ChainedStartupFailureMarker.record(
            reason: "chained-surrendered:link-silent",
            generation: 7,
            storageURL: markerURL,
            lockURL: lockURL)
        XCTAssertTrue(recorded, "a corrupt marker must be repaired, not refused")

        let state = try ChainedStartupFailureMarker.state(from: markerURL, lockURL: lockURL)
        XCTAssertEqual(state.reason, "chained-surrendered:link-silent")
        XCTAssertEqual(state.generation, 7)
        XCTAssertFalse(state.explicitRetryRequested)
        XCTAssertEqual(
            ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL),
            .marked("chained-surrendered:link-silent", generation: 7),
            "the repaired marker must read as a confirmed terminal reason, not unavailable")
    }

    /// …but CLEARING over a corrupt marker must still refuse. Repairing there would lift a gate
    /// nobody could read, which fails open; refusing merely keeps a gate that an explicit retry or
    /// a proven start will lift.
    func testClearingACorruptMarkerStillRefuses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")
        try Data("not-json".utf8).write(to: markerURL)

        XCTAssertThrowsError(
            try ChainedStartupFailureMarker.clear(
                generation: 7, storageURL: markerURL, lockURL: lockURL)
        ) { error in
            XCTAssertEqual(error as? ChainedStartupFailureMarker.StorageError, .corrupt)
        }
    }

    /// A retryable refusal clears on a later start, so it must never authorize the app's
    /// terminal OFF reconciliation. Durable reasons still do.
    func testRetryableRefusalReasonsNeverAuthorizeTerminalReconciliation() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")

        for refusal: TunnelDataPathLatch.Refusal in [
            .configurationUnreadable, .deviceStateUnavailable,
        ] {
            try ChainedStartupFailureMarker.record(
                reason: refusal.logValue, generation: 0, storageURL: markerURL, lockURL: lockURL)
            let observation = ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL)
            XCTAssertNil(observation.terminalReason, "\(refusal.logValue) must not authorize terminal teardown")
        }
        // The persistent construction downgrades share upstreamUnavailable, so it stays durable.
        try ChainedStartupFailureMarker.record(
            reason: TunnelDataPathLatch.Refusal.upstreamUnavailable.logValue,
            generation: 0, storageURL: markerURL, lockURL: lockURL)
        XCTAssertNotNil(
            ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL).terminalReason,
            "an unbuildable upstream is not cleared by a retry")
        try ChainedStartupFailureMarker.record(
            reason: TunnelDataPathLatch.Refusal.unsupportedByBuild.logValue,
            generation: 0, storageURL: markerURL, lockURL: lockURL)
        XCTAssertEqual(
            ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL).terminalReason,
            TunnelDataPathLatch.Refusal.unsupportedByBuild.logValue,
            "a durable refusal still authorizes terminal reconciliation")
    }

    /// Only a network-recoverable surrender keeps `terminalReason` nil so the armed-reconnect
    /// surface survives; every other surrender is terminal. Moved here when the destructive
    /// `TerminalReconciliation` policy was removed (fail-closed rework).
    func testOnlyNetworkRecoverableSurrenderKeepsTheArmedReconnectSurface() {
        let reasons: [(String, Bool)] = [
            (ChainedSurrenderReason.budgetExhausted.markerReason(suppressionPersisted: true), true),
            (ChainedSurrenderReason.budgetExhausted.markerReason(suppressionPersisted: false), false),
            (ChainedSurrenderReason.budgetExhausted.markerReason, false),
            (ChainedSurrenderReason.engineUnusable.markerReason, false),
            (ChainedSurrenderReason.callerContractViolation.markerReason, false),
            (ChainedSurrenderReason.clockUnusable.markerReason, false),
            ("chained-surrendered:unknown", false),
            ("chained-runtime-unavailable", false),
            ("budgetExhausted", false),
        ]
        for (reason, recoverable) in reasons {
            let observation = ChainedStartupFailureMarker.Observation.marked(reason, generation: 7)
            XCTAssertEqual(observation.terminalReason == nil, recoverable, reason)
        }
    }

    /// The marker's wire spellings must classify exactly like the latch they mirror, or a
    /// retryable refusal would start DNS-only in the provider yet still authorize OFF in the app.
    func testMarkerClassifierMatchesTheLatchClassification() {
        for refusal: TunnelDataPathLatch.Refusal in [
            .configurationUnreadable, .chainingDisabled, .unsupportedByBuild,
            .deviceStateUnavailable, .deviceIneligible(.startupCrashLoop),
            .chainedSurrendered, .upstreamUnavailable,
        ] {
            XCTAssertEqual(
                ChainedStartupFailureMarker.markerReasonIsRetryable(refusal.logValue),
                refusal.isRetryable,
                "\(refusal.logValue) classification drifted between the latch and the marker")
        }
    }

    func testMarkerObservationDistinguishesUnavailableFromTerminalReason() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChainedStartupFailureMarkerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let markerURL = directory.appendingPathComponent("marker.json")
        let lockURL = directory.appendingPathComponent("marker.lock")

        XCTAssertEqual(
            ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL),
            .clear)
        try Data("not-json".utf8).write(to: markerURL)
        XCTAssertEqual(
            ChainedStartupFailureMarker.observation(from: markerURL, lockURL: lockURL),
            .unavailable)
        XCTAssertTrue(
            ChainedStartupFailureMarker.isMarked(storageURL: markerURL, lockURL: lockURL),
            "automatic restore must stay fail-closed while the marker is unavailable")
    }
}
