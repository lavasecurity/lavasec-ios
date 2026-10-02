import XCTest

@testable import LavaSecAppServices
@testable import LavaSecFilterPipeline
@testable import LavaSecKit

private final class FocusDiagnosticEventTestBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: FocusSwitchDiagnosticEvent?

    func store(_ value: FocusSwitchDiagnosticEvent?) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func load() -> FocusSwitchDiagnosticEvent? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class FocusDiagnosticCallProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var called = false

    func markCalled() {
        lock.lock()
        called = true
        lock.unlock()
    }

    var wasCalled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return called
    }
}

/// Tests intentionally exercise the same cross-process-safe `UserDefaults` suite from two queues.
private final class FocusDiagnosticDefaultsBox: @unchecked Sendable {
    let value: UserDefaults

    init(_ value: UserDefaults) {
        self.value = value
    }
}

/// Executable coverage for the Release-visible Focus-switch diagnostic slot.
///
/// The foreground reconcile path had NO diagnostic at all: `switchToFilter`'s catch rolled back and
/// discarded the error, and the only trace was a device-log line written by `logFocusSwitchEvent`,
/// which is `#if DEBUG || LAVA_QA_TOOLS`. On a shipping build a Focus automation that never applies
/// produced nothing — device evidence 2026-08-29: 44 attempts, six builds, five days, zero
/// successes, cause unknown because nothing kept it (PR #625).
final class FocusSwitchDiagnosticsTests: XCTestCase {
    private let orderingLockURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("focus-diagnostics-tests-\(UUID().uuidString).lock")

    override func tearDown() {
        try? FileManager.default.removeItem(at: orderingLockURL)
        super.tearDown()
    }

    private func makeDefaults(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    func testEventCaptureFailsClosedBeforeReadingTheClockWhenTheOrderingLockCannotOpen() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-order-missing-\(UUID().uuidString)", isDirectory: true)
        let probe = FocusDiagnosticCallProbe()

        let event = FocusSwitchDiagnostics.captureEvent(
            in: defaults,
            orderingLockURL: missingParent.appendingPathComponent("ordering.lock"),
            now: {
                probe.markCalled()
                return Date(timeIntervalSinceReferenceDate: 1)
            })

        XCTAssertNil(event, "an unordered event must not be written as diagnostic evidence")
        XCTAssertFalse(probe.wasCalled, "the event time must be evaluated only after the required lock is held")
    }

    func testClearStillAdvancesAndDeletesWhenTheOrderingLockCannotOpen() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
                targetFilterID: "filter-old", at: Date(), reason: "deferred"),
            keepingLocalRecords: true,
            in: defaults)
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-old", reason: "cancelled", at: Date(),
            keepingLocalRecords: true, in: defaults)
        let missingParent = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-clear-missing-\(UUID().uuidString)", isDirectory: true)

        FocusSwitchDiagnostics.clear(
            in: defaults,
            orderingLockURL: missingParent.appendingPathComponent("ordering.lock"),
            now: { Date(timeIntervalSinceReferenceDate: 10) })

        XCTAssertNil(FocusSwitchDiagnostics.last(in: defaults))
        XCTAssertNil(FocusSwitchDiagnostics.lastFailure(in: defaults))
        let validLock = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-clear-valid-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: validLock) }
        let event = try XCTUnwrap(FocusSwitchDiagnostics.captureEvent(
            in: defaults, orderingLockURL: validLock,
            now: { Date(timeIntervalSinceReferenceDate: 11) }))
        XCTAssertEqual(event.clearGeneration, 1, "the fallback clear must still advance the cut-over")
    }

    func testCaptureAndClearAreTotallyOrderedInBothDirections() throws {
        let captureFirstName = "test.focus.diagnostics.\(#function).capture-first"
        let captureFirstDefaults = try makeDefaults(captureFirstName)
        defer { captureFirstDefaults.removePersistentDomain(forName: captureFirstName) }
        let captureFirstLock = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-order-capture-first-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: captureFirstLock) }
        let captureEntered = DispatchSemaphore(value: 0)
        let releaseCapture = DispatchSemaphore(value: 0)
        let captureDone = DispatchSemaphore(value: 0)
        let clearDone = DispatchSemaphore(value: 0)
        let beforeClear = FocusDiagnosticEventTestBox()
        let captureFirstDefaultsBox = FocusDiagnosticDefaultsBox(captureFirstDefaults)

        DispatchQueue(label: "focus-order.capture-first.capture").async {
            beforeClear.store(FocusSwitchDiagnostics.captureEvent(
                in: captureFirstDefaultsBox.value,
                orderingLockURL: captureFirstLock,
                now: {
                    captureEntered.signal()
                    _ = releaseCapture.wait(timeout: .now() + 5)
                    return Date(timeIntervalSinceReferenceDate: 20)
                }))
            captureDone.signal()
        }
        XCTAssertEqual(captureEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue(label: "focus-order.capture-first.clear").async {
            FocusSwitchDiagnostics.clear(
                in: captureFirstDefaultsBox.value,
                orderingLockURL: captureFirstLock,
                now: { Date(timeIntervalSinceReferenceDate: 21) })
            clearDone.signal()
        }
        XCTAssertEqual(clearDone.wait(timeout: .now() + 0.1), .timedOut)
        releaseCapture.signal()
        XCTAssertEqual(captureDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(clearDone.wait(timeout: .now() + 5), .success)
        let staleEvent = try XCTUnwrap(beforeClear.load())
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
                targetFilterID: "before-clear", at: staleEvent.at, reason: "deferred",
                clearGeneration: staleEvent.clearGeneration),
            keepingLocalRecords: true, in: captureFirstDefaults)
        XCTAssertNil(FocusSwitchDiagnostics.last(in: captureFirstDefaults))

        let clearFirstName = "test.focus.diagnostics.\(#function).clear-first"
        let clearFirstDefaults = try makeDefaults(clearFirstName)
        defer { clearFirstDefaults.removePersistentDomain(forName: clearFirstName) }
        let clearFirstLock = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-order-clear-first-\(UUID().uuidString).lock")
        defer { try? FileManager.default.removeItem(at: clearFirstLock) }
        let clearEntered = DispatchSemaphore(value: 0)
        let releaseClear = DispatchSemaphore(value: 0)
        let firstClearDone = DispatchSemaphore(value: 0)
        let postClearCaptureDone = DispatchSemaphore(value: 0)
        let afterClear = FocusDiagnosticEventTestBox()
        let clearFirstDefaultsBox = FocusDiagnosticDefaultsBox(clearFirstDefaults)

        DispatchQueue(label: "focus-order.clear-first.clear").async {
            FocusSwitchDiagnostics.clear(
                in: clearFirstDefaultsBox.value,
                orderingLockURL: clearFirstLock,
                now: {
                    clearEntered.signal()
                    _ = releaseClear.wait(timeout: .now() + 5)
                    return Date(timeIntervalSinceReferenceDate: 30)
                })
            firstClearDone.signal()
        }
        XCTAssertEqual(clearEntered.wait(timeout: .now() + 5), .success)
        DispatchQueue(label: "focus-order.clear-first.capture").async {
            afterClear.store(FocusSwitchDiagnostics.captureEvent(
                in: clearFirstDefaultsBox.value,
                orderingLockURL: clearFirstLock,
                now: { Date(timeIntervalSinceReferenceDate: 31) }))
            postClearCaptureDone.signal()
        }
        XCTAssertEqual(postClearCaptureDone.wait(timeout: .now() + 0.1), .timedOut)
        releaseClear.signal()
        XCTAssertEqual(firstClearDone.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(postClearCaptureDone.wait(timeout: .now() + 5), .success)
        let freshEvent = try XCTUnwrap(afterClear.load())
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
                targetFilterID: "after-clear", at: freshEvent.at, reason: "committed",
                clearGeneration: freshEvent.clearGeneration),
            keepingLocalRecords: true, in: clearFirstDefaults)
        XCTAssertEqual(FocusSwitchDiagnostics.last(in: clearFirstDefaults)?.targetFilterID, "after-clear")
    }

    /// A foreground reconcile failure round-trips, and names itself as one.
    func testAForegroundReconcileFailureIsRecordedForRelease() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let at = Date(timeIntervalSince1970: 1_700_000_000)
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "shared-state-unavailable",
            at: at, keepingLocalRecords: true, in: defaults)

        let record = try XCTUnwrap(
            FocusSwitchDiagnostics.lastFailure(in: defaults),
            "the failure must survive into the slot the redacted bug report reads")
        XCTAssertEqual(record.targetFilterID, "filter-comprehensive")
        XCTAssertEqual(record.reason, "shared-state-unavailable")
        XCTAssertEqual(record.at, at)
        XCTAssertEqual(
            record.outcome, FocusSwitchDiagnostics.foregroundReconcileFailedOutcome,
            "the outcome must distinguish 'tried and could not' from the headless engine's "
                + "'deferred' — the marker survives either way, but only one is a failure")
    }

    /// 🔴 A SUCCESS MUST NOT EVICT A FAILURE — the defect that forced the second slot.
    ///
    /// The headless engine records EVERY decision, `.committed` and `.alreadyActive` included,
    /// with no condition. Sharing one slot meant a routine Focus switch overwrote the failure the
    /// Release diagnostic exists to capture — and on the observed device the two interleave
    /// constantly, so the evidence would be gone before a report was filed (MECE panel, PR #625).
    func testASuccessfulSwitchCannotEvictTheFailureRecord() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "shared-state-unavailable",
            at: Date(timeIntervalSince1970: 1), keepingLocalRecords: true, in: defaults)

        // A later, ORDINARY success through the other writer.
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
                targetFilterID: "filter-balanced",
                at: Date(timeIntervalSince1970: 2),
                reason: "committed"),
            keepingLocalRecords: true, in: defaults)

        let failure = try XCTUnwrap(
            FocusSwitchDiagnostics.lastFailure(in: defaults),
            "a routine success erased the failure — the diagnostic loses the diagnosis")
        XCTAssertEqual(failure.reason, "shared-state-unavailable")
        XCTAssertEqual(
            FocusSwitchDiagnostics.last(in: defaults)?.outcome,
            HeadlessFocusSwitchOutcome.committed.rawValue,
            "and the outcome slot still means 'the last thing that happened'")
    }

    /// Withdrawn consent stops the WRITE, not merely the record already written.
    ///
    /// Rule 7. A clear that the next write undoes is theatre: the user turns Network Activity off,
    /// the slots are cleared, and the very next Focus edge repopulates them.
    func testWithdrawnConsentStopsTheWriteRatherThanClearingAfterIt() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "app-group-unavailable",
            at: Date(timeIntervalSince1970: 1), keepingLocalRecords: false, in: defaults)
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
                targetFilterID: "filter-balanced", at: Date(timeIntervalSince1970: 2),
                reason: "committed"),
            keepingLocalRecords: false, in: defaults)

        XCTAssertNil(FocusSwitchDiagnostics.lastFailure(in: defaults))
        XCTAssertNil(FocusSwitchDiagnostics.last(in: defaults))
    }

    /// Clearing erases EVERY slot.
    ///
    /// A clear that left one behind is worse than none: the user has been told the records are gone.
    func testClearErasesEverySlot() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "cancelled",
            at: Date(timeIntervalSince1970: 1), keepingLocalRecords: true, in: defaults)
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
                targetFilterID: "filter-balanced", at: Date(timeIntervalSince1970: 2),
                reason: "deferred"),
            keepingLocalRecords: true, in: defaults)
        XCTAssertNotNil(FocusSwitchDiagnostics.last(in: defaults))
        XCTAssertNotNil(FocusSwitchDiagnostics.lastFailure(in: defaults))

        FocusSwitchDiagnostics.clear(in: defaults)

        XCTAssertNil(FocusSwitchDiagnostics.last(in: defaults), "the outcome slot survived a clear")
        XCTAssertNil(
            FocusSwitchDiagnostics.lastFailure(in: defaults), "the failure slot survived a clear")
    }

    /// 🔴 THE FAILURE REACHES THE SERIALIZED REPORT, not merely the bundle.
    ///
    /// The bundle stored `lastFocusFailure` while the `incident` summary it serializes was built
    /// without it, so the field defaulted to nil and the record never left the device — the whole
    /// diagnostic inert while every other test passed (Codex, PR #625). Asserted end to end,
    /// through the dictionary the request body is built from, because that is the only place the
    /// omission is visible.
    func testTheFailureReachesTheSerializedIncidentSummary() throws {
        // RECENT, because the flag deliberately follows the 24 h rule — see the second half of
        // this test, which pins the other side of it.
        let failure = FocusSwitchDiagnosticRecord(
            outcome: FocusSwitchDiagnostics.foregroundReconcileFailedOutcome,
            targetFilterID: "filter-comprehensive",
            at: Date(),
            reason: "shared-state-unavailable")
        // A HEALTHY tunnel deliberately: the failure must be enough on its own to make the
        // section render. Built with no reconnects and no incidents so nothing else can be
        // supplying the content.
        let summary = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            lastFocusFailure: failure)

        let rendered = try XCTUnwrap(
            summary.dictionary["focus_last_failure"] as? [String: Any],
            "the failure is absent from the serialized incident summary — the record never leaves "
                + "the device, and the diagnostic is inert")
        XCTAssertEqual(rendered["reason"] as? String, "shared-state-unavailable")
        XCTAssertEqual(rendered["target_filter_id"] as? String, "filter-comprehensive")
        XCTAssertEqual(
            rendered["outcome"] as? String,
            FocusSwitchDiagnostics.foregroundReconcileFailedOutcome)
        XCTAssertTrue(
            summary.hasContent,
            "a summary carrying only a failure must still count as content, or the section is "
                + "dropped before it is ever rendered")

        // THE OTHER HALF OF THE RECENCY RULE. The record never expires, so an install-lifetime
        // failure flipping the flag forever is the misleading-true failure the 2026-07 review
        // named (OBS-1). It still SHIPS — triage context — it just stops claiming a live incident.
        let stale = BugReportIncidentSummary(
            health: TunnelHealthSnapshot(networkKind: .wifi),
            selfReconnectTimes: [],
            lastFocusFailure: FocusSwitchDiagnosticRecord(
                outcome: FocusSwitchDiagnostics.foregroundReconcileFailedOutcome,
                targetFilterID: "filter-comprehensive",
                at: Date(timeIntervalSinceNow: -25 * 60 * 60),
                reason: "shared-state-unavailable"))
        XCTAssertFalse(
            stale.hasContent, "a day-old failure must not keep claiming a live incident")
        XCTAssertNotNil(
            stale.dictionary["focus_last_failure"],
            "but it must still ship — an old record is triage context, not nothing")
    }

    /// Consent fails closed whenever it cannot be established from the persisted configuration.
    ///
    /// 🔴 ONE CHOKE POINT FOR A RULE THAT KEPT REGRESSING. Consent was resolved at three separate
    /// sites and each had to remember to fail closed independently; review found the same defect
    /// at site after site (Codex, PR #625). Absent, unreadable and undecodable all resolve to NO
    /// consent here — a default `AppConfiguration` carries `keepNetworkActivity == true`, so
    /// trusting it turns "we could not tell" into "consent granted".
    func testTryConsentSkipsContendedWritersAndKeepsTheSamePrivacyRules() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("focus-try-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lockURL = dir.appendingPathComponent("config.lock")
        let configURL = dir.appendingPathComponent("configuration.json")
        XCTAssertEqual(FocusSwitchDiagnostics.tryWithResolvedConsent(configurationURL: configURL, lockURL: lockURL) { $0 }, false)
        try Data("bad json".utf8).write(to: configURL)
        XCTAssertEqual(FocusSwitchDiagnostics.tryWithResolvedConsent(configurationURL: configURL, lockURL: lockURL) { $0 }, false)
        for granted in [false, true] {
            var config = AppConfiguration()
            config.keepNetworkActivity = granted
            try JSONEncoder().encode(config).write(to: configURL)
            XCTAssertEqual(FocusSwitchDiagnostics.tryWithResolvedConsent(configurationURL: configURL, lockURL: lockURL) { $0 }, granted)
        }
        var called = false
        FilterPublishLock.withExclusiveLock(at: lockURL) {
            let result = FocusSwitchDiagnostics.tryWithResolvedConsent(configurationURL: configURL, lockURL: lockURL) { consented in
                called = true
                return consented
            }
            XCTAssertNil(result)
        }
        XCTAssertFalse(called)
    }

    func testConsentFailsClosedWhenTheConfigurationCannotBeRead() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-consent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let lock = dir.appendingPathComponent("config.lock")

        // ABSENT.
        let missing = dir.appendingPathComponent("nope.json")
        XCTAssertFalse(
            FocusSwitchDiagnostics.withResolvedConsent(
                configurationURL: missing, lockURL: lock) { $0 },
            "an absent configuration must read as consent WITHHELD")

        // UNDECODABLE.
        let garbage = dir.appendingPathComponent("garbage.json")
        try Data("not json".utf8).write(to: garbage)
        XCTAssertFalse(
            FocusSwitchDiagnostics.withResolvedConsent(
                configurationURL: garbage, lockURL: lock) { $0 },
            "an undecodable configuration must read as consent WITHHELD")

        // AND A REAL ONE STILL READS ITS VALUE — otherwise the gate is closed for everyone and
        // the fail-closed assertions above would hold for the wrong reason.
        var granted = AppConfiguration()
        granted.keepNetworkActivity = true
        let grantedURL = dir.appendingPathComponent("granted.json")
        try JSONEncoder().encode(granted).write(to: grantedURL)
        XCTAssertTrue(
            FocusSwitchDiagnostics.withResolvedConsent(
                configurationURL: grantedURL, lockURL: lock) { $0 })

        var withdrawn = AppConfiguration()
        withdrawn.keepNetworkActivity = false
        let withdrawnURL = dir.appendingPathComponent("withdrawn.json")
        try JSONEncoder().encode(withdrawn).write(to: withdrawnURL)
        XCTAssertFalse(
            FocusSwitchDiagnostics.withResolvedConsent(
                configurationURL: withdrawnURL, lockURL: lock) { $0 })
    }

    /// 🔴 A CLEAR MUST NOT BLOCK ON THE FOCUS-SWITCH LOCK — it runs on the main thread.
    ///
    /// The inverse of a test that used to live here. An earlier revision ordered clears against the
    /// engine's whole decide-then-record span by taking the focus-switch lock, which a Focus switch
    /// holds across a COLD COMPILE. Both clear callers are `@MainActor` and synchronous, so that
    /// froze the UI for seconds on "Clear all local logs" and the Network Activity toggle
    /// (Kilo, PR #626). Chasing a microsecond diagnostic race bought a multi-second hang.
    ///
    /// Asserted by NOT blocking: hold the switch lock, then show the resolver still completes.
    func testResolvingConsentDoesNotBlockOnTheFocusSwitchLock() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("focus-noblock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configURL = dir.appendingPathComponent("config.json")
        try JSONEncoder().encode(AppConfiguration()).write(to: configURL)
        let configLock = dir.appendingPathComponent("config.lock")
        let switchLock = dir.appendingPathComponent("switch.lock")

        // Stand in for a Focus switch mid-compile: hold the switch lock throughout.
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        DispatchQueue(label: "switch").async {
            let fd = open(switchLock.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
            guard fd >= 0, flock(fd, LOCK_EX) == 0 else { held.signal(); return }
            held.signal()
            _ = release.wait(timeout: .now() + 5)
            flock(fd, LOCK_UN)
            close(fd)
        }
        XCTAssertEqual(held.wait(timeout: .now() + 5), .success)
        defer { release.signal() }

        let done = DispatchSemaphore(value: 0)
        DispatchQueue(label: "clear").async {
            FocusSwitchDiagnostics.withResolvedConsent(
                configurationURL: configURL, lockURL: configLock) { _ in }
            done.signal()
        }
        XCTAssertEqual(
            done.wait(timeout: .now() + 2), .success,
            "resolving consent blocked while a Focus switch held its lock — both clear callers are "
                + "@MainActor and synchronous, so this is a multi-second UI freeze")
    }

    /// The foreground outcome is DISTINCT from every headless outcome.
    ///
    /// They share one slot, so a reader can only tell the two paths apart by this string. If the
    /// foreground constant ever collided with a headless case, a failed apply would read as an
    /// ordinary decision and the bug this recorder exists to surface would be invisible again.
    func testTheForegroundOutcomeCannotBeMistakenForAHeadlessDecision() {
        let headless = Set(
            [
                HeadlessFocusSwitchOutcome.committed, .deferred, .alreadyActive, .disallowed,
            ].map(\.rawValue))
        XCTAssertFalse(
            headless.contains(FocusSwitchDiagnostics.foregroundReconcileFailedOutcome),
            "the foreground failure outcome collides with a headless decision, so the two paths "
                + "are indistinguishable in the one slot they share")
    }

    /// The most recent write wins, because the bug report reads exactly one record.
    ///
    /// A deterministic failure re-fires on every foreground edge, so the slot must carry the
    /// LATEST attempt rather than the first — otherwise a stale record from days ago is what
    /// reaches the report.
    func testTheLatestFailureReplacesAnEarlierRecord() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-balanced", reason: "cancelled",
            at: Date(timeIntervalSince1970: 1), keepingLocalRecords: true, in: defaults)
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "app-group-unavailable",
            at: Date(timeIntervalSince1970: 2), keepingLocalRecords: true, in: defaults)

        let record = try XCTUnwrap(FocusSwitchDiagnostics.lastFailure(in: defaults))
        XCTAssertEqual(record.targetFilterID, "filter-comprehensive")
        XCTAssertEqual(record.reason, "app-group-unavailable")
    }

    /// A delayed pre-clear reconcile failure must not overwrite a newer-generation failure that
    /// already reached the slot while the older task was suspended.
    func testAnOlderFailureCannotClobberANewerGeneration() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL,
            now: { Date(timeIntervalSinceReferenceDate: 50_000) })
        let newer = try XCTUnwrap(FocusSwitchDiagnostics.captureEvent(
            in: defaults, orderingLockURL: orderingLockURL,
            now: { Date(timeIntervalSinceReferenceDate: 50_001) }))
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-newer", reason: "newer-failure", at: newer.at,
            clearGeneration: newer.clearGeneration, keepingLocalRecords: true, in: defaults)

        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-stale", reason: "stale-failure",
            at: Date(timeIntervalSinceReferenceDate: 49_999), clearGeneration: 0,
            keepingLocalRecords: true, in: defaults)

        let record = try XCTUnwrap(FocusSwitchDiagnostics.lastFailure(in: defaults))
        XCTAssertEqual(record.targetFilterID, "filter-newer")
        XCTAssertEqual(record.reason, "newer-failure")
    }

    /// A decision made before the clear stays hidden even when its writer runs after the clear.
    ///
    /// This is the exact non-blocking race: the headless switch has already decided, the main-actor
    /// clear stamps its cut-over and removes the slots, then the switch gets scheduled and writes
    /// its old decision. The record must not return merely because it was re-added after deletion.
    func testAStaleDecisionWrittenAfterClearIsHiddenByTheWatermark() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let clearedAt = Date(timeIntervalSinceReferenceDate: 42_000)
        let staleAt = clearedAt.addingTimeInterval(-1)
        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
                targetFilterID: "filter-before-clear", at: staleAt, reason: "deferred"),
            keepingLocalRecords: true,
            in: defaults)
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-before-clear", reason: "cancelled", at: staleAt,
            keepingLocalRecords: true, in: defaults)
        XCTAssertNotNil(FocusSwitchDiagnostics.last(in: defaults))
        XCTAssertNotNil(FocusSwitchDiagnostics.lastFailure(in: defaults))

        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL, now: { clearedAt })
        XCTAssertNil(FocusSwitchDiagnostics.last(in: defaults))
        XCTAssertNil(FocusSwitchDiagnostics.lastFailure(in: defaults))

        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
                targetFilterID: "filter-balanced", at: staleAt, reason: "deferred"),
            keepingLocalRecords: true,
            in: defaults)
        FocusSwitchDiagnostics.recordForegroundReconcileFailure(
            targetFilterID: "filter-comprehensive", reason: "cancelled", at: staleAt,
            keepingLocalRecords: true, in: defaults)

        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: defaults),
            "a pre-clear headless decision re-added after deletion must stay hidden")
        XCTAssertNil(
            FocusSwitchDiagnostics.lastFailure(in: defaults),
            "the watermark must cover the foreground failure slot too")
    }

    /// The cut-over is inclusive: a record at the exact clear instant is pre-clear, while a later
    /// decision remains visible.
    func testTheWatermarkExcludesItsBoundaryButKeepsLaterDecisions() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let clearedAt = Date(timeIntervalSinceReferenceDate: 43_000)
        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL, now: { clearedAt })

        FocusSwitchDiagnostics.record(
            FocusSwitchDiagnosticRecord(
                outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
                targetFilterID: "filter-boundary", at: clearedAt, reason: "committed"),
            keepingLocalRecords: true,
            in: defaults)
        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: defaults),
            "a decision at the clear instant must not leak through the cut-over")

        let laterEvent = try XCTUnwrap(FocusSwitchDiagnostics.captureEvent(
            in: defaults, orderingLockURL: orderingLockURL,
            now: { clearedAt.addingTimeInterval(0.001) }))
        let later = FocusSwitchDiagnosticRecord(
            outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
            targetFilterID: "filter-later", at: laterEvent.at,
            reason: "committed", clearGeneration: laterEvent.clearGeneration)
        FocusSwitchDiagnostics.record(later, keepingLocalRecords: true, in: defaults)
        XCTAssertEqual(
            FocusSwitchDiagnostics.last(in: defaults), later,
            "a decision after the clear must remain diagnosable")
    }

    /// A wall-clock correction cannot suppress a post-clear decision for the rest of the future.
    func testAClockRollbackDoesNotHideAPostClearDecision() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let clearedAt = Date(timeIntervalSinceReferenceDate: 45_000)
        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL, now: { clearedAt })

        let rolledBackEvent = try XCTUnwrap(FocusSwitchDiagnostics.captureEvent(
            in: defaults, orderingLockURL: orderingLockURL,
            now: { clearedAt.addingTimeInterval(-86_400) }))
        let record = FocusSwitchDiagnosticRecord(
            outcome: HeadlessFocusSwitchOutcome.committed.rawValue,
            targetFilterID: "filter-after-clock-correction",
            at: rolledBackEvent.at,
            reason: "committed",
            clearGeneration: rolledBackEvent.clearGeneration)
        FocusSwitchDiagnostics.record(record, keepingLocalRecords: true, in: defaults)

        XCTAssertEqual(
            FocusSwitchDiagnostics.last(in: defaults), record,
            "a post-clear decision must remain visible after the wall clock moves backwards")
    }

    /// A clock adjustment cannot move the durable clear cut-over backwards.
    func testAnOlderClearCannotMoveTheWatermarkBackwards() throws {
        let name = "test.focus.diagnostics.\(#function)"
        let defaults = try makeDefaults(name)
        defer { defaults.removePersistentDomain(forName: name) }

        let newestClear = Date(timeIntervalSinceReferenceDate: 44_000)
        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL, now: { newestClear })
        FocusSwitchDiagnostics.clear(
            in: defaults, orderingLockURL: orderingLockURL,
            now: { newestClear.addingTimeInterval(-10) })

        let between = FocusSwitchDiagnosticRecord(
            outcome: HeadlessFocusSwitchOutcome.deferred.rawValue,
            targetFilterID: "filter-between-clears",
            at: newestClear.addingTimeInterval(-1),
            reason: "deferred")
        FocusSwitchDiagnostics.record(between, keepingLocalRecords: true, in: defaults)

        XCTAssertNil(
            FocusSwitchDiagnostics.last(in: defaults),
            "an older clear must not make a record newer than it but older than the latest clear visible")
    }
}
