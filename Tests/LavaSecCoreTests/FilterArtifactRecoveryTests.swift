import XCTest
import LavaSecCore

final class FilterArtifactRecoveryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000)

    private func assess(_ outcome: FilterArtifactRepairStatus.Outcome, serving: Bool = false,
                        loading: Bool = false, identity: String = "current", age: TimeInterval = 0) -> FilterArtifactRecoveryAssessment {
        .assess(isServing: serving, reloadInFlight: loading, configurationIdentity: "current",
                repair: .init(configurationIdentity: identity, outcome: outcome, recordedAt: now.addingTimeInterval(-age)),
                failureStartedAt: now.addingTimeInterval(-600), now: now)
    }

    func testUsableResidentOrLastKnownGoodSuppressesEveryIntervention() {
        for outcome: FilterArtifactRepairStatus.Outcome in [.repairing, .waitingForRetry, .published, .selectionOverBudget, .customSourceUnavailable] {
            XCTAssertEqual(assess(outcome, serving: true), .serving)
        }
    }

    func testAutomaticWorkAndRetryableFailuresNeverBecomeUserActions() {
        XCTAssertEqual(assess(.repairing), .repairing)
        XCTAssertEqual(assess(.selectionOverBudget, loading: true), .repairing)
        XCTAssertEqual(assess(.waitingForRetry), .waitingForAutomaticRepair)
        XCTAssertEqual(assess(.published), .waitingForAutomaticRepair, "Publication is not verified adoption")
        XCTAssertEqual(FilterArtifactRecoveryAssessment.assess(isServing: false, reloadInFlight: false,
            configurationIdentity: "current", repair: nil, now: now), .waitingForAutomaticRepair)
    }

    func testOnlyConcreteRemediesForFreshCurrentEvidenceEscalate() {
        XCTAssertEqual(assess(.selectionOverBudget), .requiresUserAction(.reviewFilterSelection))
        XCTAssertEqual(assess(.customSourceUnavailable), .requiresUserAction(.refreshCustomSources))
        for outcome: FilterArtifactRepairStatus.Outcome in [.selectionOverBudget, .customSourceUnavailable] {
            XCTAssertNil(assess(outcome, identity: "superseded").intervention)
            XCTAssertNil(assess(outcome, age: 601).intervention)
            XCTAssertNil(assess(outcome, age: -1).intervention)
        }
    }

    func testOutageAndElapsedTimeWithoutTriageCannotNotify() {
        let health = TunnelHealthSnapshot(failClosedServedQueryCount: 10, lastFailClosedAt: now,
                                          lastFailClosedReason: "snapshot-unavailable")
        XCTAssertNil(ProtectionConnectivityNotificationPolicy.notification(
            for: .init(severity: .needsReconnect, primaryAction: .reconnect), health: health, history: .empty,
            filteringUnavailable: true, filteringUnavailableSince: now.addingTimeInterval(-600), now: now))
    }

    func testPriorIncidentEvidenceCannotAuthorizeANewIntervention() {
        let result = FilterArtifactRecoveryAssessment.assess(isServing: false, reloadInFlight: false,
            configurationIdentity: "current",
            repair: .init(configurationIdentity: "current", outcome: .selectionOverBudget,
                          recordedAt: now.addingTimeInterval(-1)), failureStartedAt: now, now: now)
        XCTAssertNil(result.intervention)
    }

    func testExistingTunnelPollReevaluatesRepairBeforeConfigurationGuards() throws {
        let source = sourceCodeOnly(try readSource(.packetTunnelProviderFocusConfigPoll))
        let tick = try sourceBlock(in: source, startingAt: "private func reloadSnapshotIfConfigurationGenerationAdvanced() {")
        let reevaluation = try XCTUnwrap(tick.range(of:
            "if filteringUnavailableNoticeStartedAt != nil { scheduleProtectionNotificationIfNeeded() }")?.lowerBound)
        let firstGuard = try XCTUnwrap(tick.range(of: "guard ")?.lowerBound)
        XCTAssertLessThan(reevaluation, firstGuard, "Unchanged generation or in-flight reload cannot strand completed app evidence")
    }

    func testLimitOrGenerationChangesInvalidateRepairEvidenceWithoutChangingFilterInputs() {
        var configuration = AppConfiguration()
        let original = FilterArtifactRepairStatus.identity(for: configuration, snapshotFingerprint: "same-filter")
        configuration.isPaid = true
        let upgraded = FilterArtifactRepairStatus.identity(for: configuration, snapshotFingerprint: "same-filter")
        XCTAssertNotEqual(original, upgraded)
        configuration.configurationGeneration += 1
        XCTAssertNotEqual(upgraded, FilterArtifactRepairStatus.identity(for: configuration, snapshotFingerprint: "same-filter"))
    }

    func testUnknownTriageCannotClearAnOutstandingIncidentOrRenewItsNotification() {
        let history = ProtectionConnectivityNotificationHistory(unresolvedProblemNotificationID: "owned",
                                                                 unresolvedProblemKind: .filteringUnavailable)
        let identifiers = ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: .init(severity: .healthy, primaryAction: .turnOff), health: TunnelHealthSnapshot(), history: history,
            filteringUnavailable: true, now: now)
        XCTAssertTrue(identifiers.isEmpty)
        XCTAssertTrue(ProtectionConnectivityNotificationPolicy.resolvedProblemNotificationIdentifiers(
            for: .init(severity: .healthy, primaryAction: .turnOff), health: TunnelHealthSnapshot(), history: history,
            filteringUnavailable: nil, now: now).isEmpty, "An app reader cannot assert tunnel recovery")
    }

    @MainActor
    func testOverlappingRepairsRemainInProgressUntilBothComplete() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "current", now: now)
        let second = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "current", now: now)
        FilterArtifactRepairStatusStore.finish(first, outcome: .selectionOverBudget, now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .repairing)
        FilterArtifactRepairStatusStore.finish(second, outcome: .published, now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .published)
        FilterArtifactRepairStatusStore.finish(first, outcome: .selectionOverBudget, now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .published)
    }

    @MainActor
    func testRefreshCanCompleteAgainstItsOwnPersistedGeneration() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let token = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "before-save", now: now)
        FilterArtifactRepairStatusStore.finish(token, outcome: .selectionOverBudget,
            completedConfigurationIdentity: "after-save", now: now)
        let status = FilterArtifactRepairStatusStore.load(at: url)
        XCTAssertEqual(status?.configurationIdentity, "after-save")
        XCTAssertEqual(FilterArtifactRecoveryAssessment.assess(isServing: false, reloadInFlight: false,
            configurationIdentity: "after-save", repair: status, failureStartedAt: now, now: now),
            .requiresUserAction(.reviewFilterSelection))
    }

    @MainActor
    func testOlderGenerationWorkCannotStrandACompletedRefreshInRepairing() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let foreground = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "before-save", now: now)
        let background = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "before-save", now: now)
        FilterArtifactRepairStatusStore.finish(foreground, outcome: .selectionOverBudget,
            completedConfigurationIdentity: "after-save", now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .selectionOverBudget)
        FilterArtifactRepairStatusStore.finish(background, outcome: .published, now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.configurationIdentity, "after-save")
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .selectionOverBudget)
    }

    @MainActor
    func testSupersededCompletionCannotReplaceTheNewConfigurationsEvidence() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "old", now: now)
        let second = FilterArtifactRepairStatusStore.begin(at: url, configurationIdentity: "new", now: now)
        FilterArtifactRepairStatusStore.finish(second, outcome: .published, now: now)
        FilterArtifactRepairStatusStore.finish(first, outcome: .selectionOverBudget,
            completedConfigurationIdentity: "old-refreshed", now: now)
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.configurationIdentity, "new")
        XCTAssertEqual(FilterArtifactRepairStatusStore.load(at: url)?.outcome, .published)
    }

    func testEvidenceReadersDoNotRepairMissingCorruptOrOversizedFiles() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertNil(FilterArtifactRepairStatusStore.load(at: url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        for data in [Data("bad".utf8), Data(repeating: 32, count: 4097)] {
            try data.write(to: url)
            XCTAssertNil(FilterArtifactRepairStatusStore.load(at: url))
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }
}
