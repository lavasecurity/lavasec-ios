import XCTest
@testable import LavaSecKit

@MainActor
final class ProtectionOnDemandArmTests: XCTestCase {
    private enum TestFailure: Error { case stalePreferences }

    func testUniversalRuleRequiresExactlyOneUnconditionalAnyInterfaceConnect() {
        let universal = ProtectionOnDemandArm.RuleSnapshot(
            isConnectRule: true, matchesAnyInterface: true, hasConditions: false)
        XCTAssertTrue(ProtectionOnDemandArm.hasUniversalConnectRule([universal]))
        XCTAssertFalse(ProtectionOnDemandArm.hasUniversalConnectRule([]))
        XCTAssertFalse(ProtectionOnDemandArm.hasUniversalConnectRule([universal, universal]))
        XCTAssertFalse(ProtectionOnDemandArm.hasUniversalConnectRule([
            .init(isConnectRule: false, matchesAnyInterface: true, hasConditions: false), universal]))
        XCTAssertFalse(ProtectionOnDemandArm.hasUniversalConnectRule([
            .init(isConnectRule: true, matchesAnyInterface: false, hasConditions: false)]))
        XCTAssertFalse(ProtectionOnDemandArm.hasUniversalConnectRule([
            .init(isConnectRule: true, matchesAnyInterface: true, hasConditions: true)]))
    }

    func testTransientSaveFailureReloadsAndVerifiesBeforeConfirming() async throws {
        var loads = 0
        var saves = 0
        var waits = 0
        let confirmed = try await ProtectionOnDemandArm.perform(
            validateOwnership: { true },
            readState: { loads += 1; return .init(isConnected: true, isArmed: false) },
            saveAndVerify: {
                saves += 1
                if saves == 1 { throw TestFailure.stalePreferences }
            },
            waitBeforeRetry: { waits += 1 })
        XCTAssertTrue(confirmed)
        XCTAssertEqual(loads, 2)
        XCTAssertEqual(saves, 2)
        XCTAssertEqual(waits, 1)
    }

    func testFailedReadbackIsBoundedAndNeverReportsConfirmed() async {
        var loads = 0
        var saves = 0
        var waits = 0
        do {
            _ = try await ProtectionOnDemandArm.perform(
                validateOwnership: { true },
                readState: { loads += 1; return .init(isConnected: true, isArmed: false) },
                saveAndVerify: { saves += 1; throw ProtectionOnDemandArm.Failure.verificationFailed },
                waitBeforeRetry: { waits += 1 })
            XCTFail("unverified saved state must not confirm recovery")
        } catch {
            XCTAssertEqual(error as? ProtectionOnDemandArm.Failure, .verificationFailed)
        }
        XCTAssertEqual(loads, 3)
        XCTAssertEqual(saves, 3)
        XCTAssertEqual(waits, 2)
    }

    func testNewerOffDuringRetryPreventsTheNextProfileLoadOrSave() async {
        var intentRevision = 1
        var loads = 0
        var saves = 0
        do {
            _ = try await ProtectionOnDemandArm.perform(
                validateOwnership: { intentRevision == 1 },
                readState: { loads += 1; return .init(isConnected: true, isArmed: false) },
                saveAndVerify: { saves += 1; throw TestFailure.stalePreferences },
                waitBeforeRetry: { intentRevision = 2 })
            XCTFail("OFF must retire the pending repair")
        } catch {
            XCTAssertEqual(error as? ProtectionOnDemandArm.Failure, .ownershipLost)
        }
        XCTAssertEqual(loads, 1)
        XCTAssertEqual(saves, 1)
    }

    func testNewerExternalRestartDuringProfileReadPreventsSaving() async {
        var restartGeneration = 1
        var saves = 0
        do {
            _ = try await ProtectionOnDemandArm.perform(
                validateOwnership: { restartGeneration == 1 },
                readState: {
                    restartGeneration = 2
                    return .init(isConnected: true, isArmed: false)
                },
                saveAndVerify: { saves += 1 },
                waitBeforeRetry: {})
            XCTFail("an old generation must not arm the replacement")
        } catch {
            XCTAssertEqual(error as? ProtectionOnDemandArm.Failure, .ownershipLost)
        }
        XCTAssertEqual(saves, 0)
    }

    func testDisconnectedProfileNeverArms() async throws {
        var saves = 0
        let confirmed = try await ProtectionOnDemandArm.perform(
            validateOwnership: { true },
            readState: { .init(isConnected: false, isArmed: false) },
            saveAndVerify: { saves += 1 },
            waitBeforeRetry: {})
        XCTAssertFalse(confirmed)
        XCTAssertEqual(saves, 0)
    }

    func testAlreadyVerifiedProfileConfirmsWithoutRewritingIt() async throws {
        var saves = 0
        let confirmed = try await ProtectionOnDemandArm.perform(
            validateOwnership: { true },
            readState: { .init(isConnected: true, isArmed: true) },
            saveAndVerify: { saves += 1 },
            waitBeforeRetry: {})
        XCTAssertTrue(confirmed)
        XCTAssertEqual(saves, 0)
    }

    func testCancellationDuringRetryPreventsFurtherSaves() async {
        var saves = 0
        let task = Task { @MainActor in
            try await ProtectionOnDemandArm.perform(
                validateOwnership: { true },
                readState: { .init(isConnected: true, isArmed: false) },
                saveAndVerify: { saves += 1; throw TestFailure.stalePreferences },
                waitBeforeRetry: {
                    withUnsafeCurrentTask { $0?.cancel() }
                })
        }
        do {
            _ = try await task.value
            XCTFail("cancelled repair must not confirm or retry")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(saves, 1)
    }

    func testForegroundRepairWaitsForPendingArmBeforeLoadingAndPublishingItsSnapshot() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let model = ForegroundOnDemandModel()
        let saveGate = ForegroundOnDemandCallbackGate()
        let readbackGate = ForegroundOnDemandCallbackGate()
        let arm = Task { @MainActor in
            var confirmed = false
            defer { model.finishArm(confirmed: confirmed) }
            confirmed = try await ProtectionLifecycleMutationFence.withDescendantMutation(
                lockFileURL: lockURL,
                validateLocalOwnership: { true },
                validateExternalGeneration: { true }) {
                    var currentManager: ForegroundOnDemandManager?
                    return try await ProtectionOnDemandArm.perform(
                        validateOwnership: { true },
                        readState: {
                            let manager = ForegroundOnDemandManager(isArmed: model.savedIsArmed)
                            currentManager = manager
                            model.cachedManager = manager
                            return .init(isConnected: true,
                                isArmed: manager.isArmed && model.confirmation == true)
                        },
                        saveAndVerify: {
                            let manager = try XCTUnwrap(currentManager)
                            manager.isArmed = true
                            model.confirmation = false
                            await saveGate.suspend()
                            model.savedIsArmed = true
                            await readbackGate.suspend()
                            manager.isArmed = model.savedIsArmed
                            model.confirmation = true
                        },
                        waitBeforeRetry: {})
                }
        }
        defer {
            saveGate.resume()
            readbackGate.resume()
            arm.cancel()
        }
        guard await waitForForegroundRepairCondition({ saveGate.isSuspended }) else { return }
        let armingManager = try XCTUnwrap(model.cachedManager)
        var ownershipProbes = 0
        var reads = 0
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { ownershipProbes += 1; return true },
                readState: {
                    reads += 1
                    return ForegroundOnDemandManager(isArmed: model.savedIsArmed)
                },
                applyState: { manager in
                    publications += 1
                    model.cachedManager = manager
                    _ = model.observeStatus(from: manager)
                    _ = model.requestRepair()
                })
        }
        defer { foreground.cancel() }
        guard await waitForForegroundRepairCondition({ ownershipProbes > 0 }) else { return }
        XCTAssertEqual(reads, 0, "A foreground snapshot must not load the disabled profile during the save.")
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(model.cachedManager === armingManager)

        saveGate.resume()
        guard await waitForForegroundRepairCondition({ readbackGate.isSuspended }) else { return }
        XCTAssertEqual(reads, 0, "The same fence must cover saved-rule readback as well as the save.")
        readbackGate.resume()
        try await arm.value
        try await foreground.value

        XCTAssertEqual(reads, 1)
        XCTAssertEqual(publications, 1)
        XCTAssertTrue(try XCTUnwrap(model.cachedManager).isArmed)
        // The cached NE status notification and forced saved-profile reconciliation must each
        // retain the arm's confirmation. Same-status reducer effects are always empty, so check
        // the shared confirmation directly after each notification.
        XCTAssertEqual(model.confirmation, true)
        _ = model.observeStatus(from: try XCTUnwrap(model.cachedManager))
        XCTAssertEqual(model.confirmation, true, "The published cache must not clear the completed arm.")
        _ = model.observeStatus(from: ForegroundOnDemandManager(isArmed: model.savedIsArmed))
        XCTAssertEqual(model.confirmation, true)
        XCTAssertTrue(model.savedIsArmed)
        XCTAssertEqual(model.requestRepair(), [], "A successful snapshot must not reserve a duplicate arm.")
    }

    func testForegroundSnapshotKeepsTheFenceAcrossItsReadAndSynchronousPublication() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let readGate = ForegroundOnDemandCallbackGate()
        var revision = 1
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { revision == 1 },
                readState: { await readGate.suspend(); return 42 },
                applyState: { snapshot in
                    XCTAssertEqual(snapshot, 42)
                    let competing = try? ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
                    XCTAssertNil(competing, "Publication must remain inside the snapshot's fence.")
                    competing?.release()
                    publications += 1
                    // Minting a fresh observation epoch legitimately changes local identity. The
                    // helper must not treat this synchronous admitted effect as ownership loss.
                    revision = 2
                })
        }
        defer { readGate.resume(); foreground.cancel() }
        guard await waitForForegroundRepairCondition({ readGate.isSuspended }) else { return }
        let competing = try ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false)
        XCTAssertNil(competing, "An arm must not start between the foreground read and publication.")
        competing?.release()
        readGate.resume()
        try await foreground.value
        XCTAssertEqual(publications, 1)
        XCTAssertEqual(revision, 2)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testOffWhileForegroundRepairWaitsPreventsTheProfileReadAndPublication() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let owner = try XCTUnwrap(ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false))
        defer { owner.release() }
        var ownsRequest = true
        var ownershipProbes = 0
        var reads = 0
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { ownershipProbes += 1; return ownsRequest },
                readState: { reads += 1; return true },
                applyState: { _ in publications += 1 })
        }
        defer { foreground.cancel() }
        guard await waitForForegroundRepairCondition({ ownershipProbes > 0 }) else { return }
        ownsRequest = false
        owner.release()
        do {
            try await foreground.value
            XCTFail("An OFF accepted while the foreground request waits must retire that request.")
        } catch {
            XCTAssertEqual(error as? ProtectionLifecycleMutationFenceError, .ownershipLost)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testOffDuringForegroundProfileReadPreventsPublicationAndReleasesTheFence() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let readGate = ForegroundOnDemandCallbackGate()
        var ownsRequest = true
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { ownsRequest },
                readState: { await readGate.suspend(); return true },
                applyState: { _ in publications += 1 })
        }
        defer { readGate.resume(); foreground.cancel() }
        guard await waitForForegroundRepairCondition({ readGate.isSuspended }) else { return }
        ownsRequest = false
        readGate.resume()
        do {
            try await foreground.value
            XCTFail("A callback that returns after OFF cannot publish its captured manager.")
        } catch {
            XCTAssertEqual(error as? ProtectionLifecycleMutationFenceError, .ownershipLost)
        }
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testDNSOnlySamplerStopWhileForegroundRepairWaitsDoesNotRetireTheRequest() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let owner = try XCTUnwrap(ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false))
        defer { owner.release() }
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        _ = lifetime.beginSampling()
        let activityGeneration = lifetime.activityGeneration
        var ownershipProbes = 0
        var reads = 0
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: {
                    ownershipProbes += 1
                    return lifetime.isActive && lifetime.activityGeneration == activityGeneration
                },
                readState: { reads += 1; return true },
                applyState: { _ in publications += 1 })
        }
        defer { foreground.cancel() }
        guard await waitForForegroundRepairCondition({ ownershipProbes > 0 }) else { return }
        XCTAssertEqual(reads, 0)
        // The authoritative DNS-only observation stops only its sampler while this fence is busy.
        lifetime.invalidateSampling()
        owner.release()
        try await foreground.value
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(publications, 1)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testActivityCycleDuringForegroundReadRetiresTheOlderRequest() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let readGate = ForegroundOnDemandCallbackGate()
        var lifetime = ChainedObservationLifetime()
        lifetime.setActive(true)
        let activityGeneration = lifetime.activityGeneration
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { lifetime.isActive && lifetime.activityGeneration == activityGeneration },
                readState: { await readGate.suspend(); return true },
                applyState: { _ in publications += 1 })
        }
        defer { readGate.resume(); foreground.cancel() }
        guard await waitForForegroundRepairCondition({ readGate.isSuspended }) else { return }
        lifetime.setActive(false)
        lifetime.setActive(true)
        readGate.resume()
        do {
            try await foreground.value
            XCTFail("Returning to foreground cannot revive a request from an older activity interval.")
        } catch {
            XCTAssertEqual(error as? ProtectionLifecycleMutationFenceError, .ownershipLost)
        }
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testCancellationWhileForegroundRepairWaitsPreventsTheProfileRead() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let owner = try XCTUnwrap(ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false))
        defer { owner.release() }
        var ownershipProbes = 0
        var reads = 0
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { ownershipProbes += 1; return true },
                readState: { reads += 1; return true },
                applyState: { _ in publications += 1 })
        }
        defer { foreground.cancel() }
        guard await waitForForegroundRepairCondition({ ownershipProbes > 0 }) else { return }
        foreground.cancel()
        owner.release()
        do {
            try await foreground.value
            XCTFail("Cancellation while waiting must prevent the first profile read.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testCancellationDuringForegroundReadPreventsPublicationAndReleasesTheFence() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        let readGate = ForegroundOnDemandCallbackGate()
        var publications = 0
        let foreground = Task { @MainActor in
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { true },
                readState: { await readGate.suspend(); return true },
                applyState: { _ in publications += 1 })
        }
        defer { readGate.resume(); foreground.cancel() }
        guard await waitForForegroundRepairCondition({ readGate.isSuspended }) else { return }
        foreground.cancel()
        readGate.resume()
        do {
            try await foreground.value
            XCTFail("A non-cancellable platform callback cannot publish after task cancellation.")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    func testForegroundReadErrorDoesNotPublishAndReleasesTheFence() async throws {
        let directory = try makeForegroundRepairDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let lockURL = directory.appendingPathComponent("mutation.lock")
        var publications = 0
        do {
            try await ProtectionOnDemandArm.refreshForForegroundRepair(
                lockFileURL: lockURL,
                validateOwnership: { true },
                readState: { () async throws -> Bool in throw TestFailure.stalePreferences },
                applyState: { _ in publications += 1 })
            XCTFail("A failed profile read must propagate its original error.")
        } catch TestFailure.stalePreferences {
            // Expected.
        }
        XCTAssertEqual(publications, 0)
        try assertForegroundRepairFenceReleased(lockURL)
    }

    private func makeForegroundRepairDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("on-demand-foreground-repair-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func waitForForegroundRepairCondition(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        guard condition() else {
            XCTFail("The foreground repair did not reach its expected callback boundary.", file: file, line: line)
            return false
        }
        return true
    }

    private func assertForegroundRepairFenceReleased(
        _ lockURL: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let owner = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: lockURL, wait: false),
            "An exited foreground request must release the mutation fence.", file: file, line: line)
        owner.release()
    }
}

@MainActor
private final class ForegroundOnDemandManager {
    var isArmed: Bool
    init(isArmed: Bool) { self.isArmed = isArmed }
}

@MainActor
private final class ForegroundOnDemandModel {
    private var lifecycle = ChainedConnectLifecyclePolicy.State()
    var cachedManager: ForegroundOnDemandManager?
    var savedIsArmed = false
    var confirmation: Bool? = false

    init() {
        _ = ChainedConnectLifecyclePolicy.reduce(state: &lifecycle,
            event: .statusChanged(.connected, onDemandConfirmed: false, userInitiated: false, now: 0))
        _ = ChainedConnectLifecyclePolicy.reduce(state: &lifecycle,
            event: .observed(connection: 1, observation: .dnsOnly, now: 1))
    }

    func finishArm(confirmed: Bool) {
        _ = ChainedConnectLifecyclePolicy.reduce(state: &lifecycle,
            event: .onDemandArmFinished(id: 1, confirmed: confirmed))
    }

    func observeStatus(from manager: ForegroundOnDemandManager) -> [ChainedConnectLifecyclePolicy.Effect] {
        // Mirror the app's seed-only-if-absent and clear-only reconciliation while exercising the
        // real reducer. The fresh saved manager must not conceal a false set by an older cache.
        if confirmation == nil { confirmation = manager.isArmed }
        if !manager.isArmed, confirmation == true { confirmation = false }
        return ChainedConnectLifecyclePolicy.reduce(state: &lifecycle,
            event: .statusChanged(.connected, onDemandConfirmed: confirmation == true,
                userInitiated: false, now: 2))
    }

    func requestRepair() -> [ChainedConnectLifecyclePolicy.Effect] {
        ChainedConnectLifecyclePolicy.reduce(state: &lifecycle,
            event: .onDemandRepairRequested(connection: 1, startsNewObservation: false, now: 2))
    }
}

@MainActor
private final class ForegroundOnDemandCallbackGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isReleased = false
    private(set) var isSuspended = false

    func suspend() async {
        isSuspended = true
        guard !isReleased else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        isReleased = true
        continuation?.resume()
        continuation = nil
    }
}
