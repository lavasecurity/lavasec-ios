import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

@MainActor
final class VPNLifecycleControllerTests: XCTestCase {
    private static let providerBundleID = "com.lavasec.app.tunnel"

    func testLoadExistingPrefersActiveManagerThenCanonicalDisplayName() async throws {
        let fixture = Fixture()
        let legacyIdle = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .disconnected)
        let currentIdle = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        let legacyActive = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .connected)
        let foreignVPN = FakeVPNManager(displayName: "Other VPN", bundleID: "com.other.vpn", status: .connected)
        fixture.repository.managers = [legacyIdle, currentIdle, legacyActive, foreignVPN]

        let selected = try await fixture.controller.loadExistingManager()

        XCTAssertTrue(selected === legacyActive, "An actively connected Lava manager outranks an idle one with the canonical name.")
        let all = try await fixture.controller.matchingManagers()
        XCTAssertEqual(all.map(\.displayName), ["Lava Sec", "Lava Security", "Lava Sec"])
        XCTAssertFalse(all.contains { $0 === foreignVPN }, "Foreign VPN configurations must never be selected or touched.")
    }

    func testLoadOrCreateMakesConfiguredManagerWhenNoneExists() async throws {
        let fixture = Fixture()

        let manager = try await fixture.controller.loadOrCreateManager()

        XCTAssertTrue(fixture.repository.madeManagers.first === manager)
        XCTAssertTrue(fixture.repository.configuredManagers.contains { $0 === manager })
        XCTAssertTrue(fixture.repository.savedManagers.contains { $0 === manager })
    }

    func testLoadOrCreateReusesAndReconfiguresExistingManager() async throws {
        let fixture = Fixture()
        let existing = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [existing]

        let manager = try await fixture.controller.loadOrCreateManager()

        XCTAssertTrue(manager === existing)
        XCTAssertTrue(fixture.repository.madeManagers.isEmpty)
        XCTAssertTrue(fixture.repository.configuredManagers.contains { $0 === existing })
        XCTAssertTrue(fixture.repository.savedManagers.contains { $0 === existing })
    }

    func testLoadOrCreateRetriesTransientEmptyLoadBeforeCreating() async throws {
        let fixture = Fixture()
        let existing = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        // iOS returns an empty list on the first query (transient, e.g. during a
        // network handoff), then the saved profile reappears.
        var loads = 0
        fixture.repository.onLoadAll = {
            loads += 1
            if loads >= 2 {
                fixture.repository.managers = [existing]
            }
        }

        let manager = try await fixture.controller.loadOrCreateManager()

        XCTAssertTrue(manager === existing, "A transient empty load must reuse the existing profile, not mint a new one.")
        XCTAssertTrue(
            fixture.repository.madeManagers.isEmpty,
            "No new manager (and so no VPN-permission re-prompt) when the profile reappears on retry."
        )
        XCTAssertEqual(fixture.sleepRequests, [0.4], "One retry delay before the profile reappeared on the second load.")
        XCTAssertTrue(fixture.events.contains { $0.0 == "load-existing-manager-recovered-after-empty" })
        XCTAssertFalse(fixture.events.contains { $0.0 == "load-or-create-creating-new-manager" })
    }

    func testLoadOrCreateCreatesNewManagerOnlyAfterRetriesStayEmpty() async throws {
        let fixture = Fixture()

        let manager = try await fixture.controller.loadOrCreateManager()

        XCTAssertTrue(fixture.repository.madeManagers.first === manager)
        // Exhausts the configured retries (each with a delay) before creating.
        XCTAssertEqual(fixture.sleepRequests, [0.4, 0.4])
        XCTAssertTrue(fixture.events.contains { $0.0 == "load-or-create-creating-new-manager" })
    }

    func testLoadOrCreateDoesNotMutateAfterOwnershipIsLostDuringResolve() async {
        let fixture = Fixture()
        let gate = VPNRepositoryLoadGate()
        var ownsLifecycle = true
        fixture.repository.onLoadAll = {
            await gate.wait()
        }

        let load = Task { @MainActor in
            try await fixture.controller.loadOrCreateManager(
                continueIfOwned: { ownsLifecycle }
            )
        }
        await gate.waitUntilStarted()
        ownsLifecycle = false
        gate.release()

        do {
            _ = try await load.value
            XCTFail("A stale lifecycle owner must abort before configuring or saving a manager.")
        } catch {
            XCTAssertEqual(error as? VPNLifecycleMutationError, .superseded)
        }
        XCTAssertTrue(fixture.repository.madeManagers.isEmpty)
        XCTAssertTrue(fixture.repository.configuredManagers.isEmpty)
        XCTAssertTrue(fixture.repository.savedManagers.isEmpty)
        XCTAssertTrue(fixture.repository.removedManagers.isEmpty)
    }

    func testGatedPreferenceSaveFenceBlocksRestartAfterLogicalLeaseExpiry() async throws {
        let fixture = Fixture()
        let saveGate = VPNRepositoryLoadGate()
        fixture.repository.onSaveAndReload = {
            await saveGate.wait()
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-lifecycle-fence-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fenceURL = directory.appendingPathComponent("mutation.lock")

        let clock = FakeProtectionClock(now: Date(timeIntervalSinceReferenceDate: 1_000))
        let tokenSequence = VPNLeaseTokenSequence(["automatic", "restart"])
        let leaseStore = ProtectionLifecycleLeaseStore(
            storage: FakeProtectionKeyValueStore(),
            lock: ProtectionNSLock(),
            clock: clock,
            makeToken: { tokenSequence.next() }
        )
        let automaticLease = try XCTUnwrap(
            leaseStore.claimAutomaticRestore(
                expectedExternalRestartGeneration: nil,
                leaseDuration: 10
            )
        )
        let validateOwnership: @MainActor () -> Bool = {
            (try? leaseStore.renew(automaticLease, leaseDuration: 10)) == true
        }

        let load = Task { @MainActor in
            try await fixture.controller.loadOrCreateManager(
                continueIfOwned: validateOwnership,
                performPreferenceMutation: { operation in
                    try await ProtectionLifecycleMutationFence.withOwnedMutation(
                        lockFileURL: fenceURL,
                        validateOwnership: validateOwnership,
                        operation: operation
                    )
                }
            )
        }
        await saveGate.waitUntilStarted()

        // Simulate task/process suspension: the logical lease expires and even cancelling the
        // waiter cannot release a non-cancellable preferences callback's kernel fence.
        clock.advance(seconds: 11)
        load.cancel()

        func claimRestartLikeProduction() throws -> ProtectionLifecycleLease? {
            guard let fence = try ProtectionLifecycleMutationFence.acquire(
                lockFileURL: fenceURL,
                wait: false
            ) else {
                return nil
            }
            defer { fence.release() }
            return try leaseStore.claimExplicitRestart(leaseDuration: 10)
        }

        XCTAssertNil(try claimRestartLikeProduction())
        XCTAssertNil(
            try leaseStore.currentExternalRestartGeneration(),
            "A restart rejected by the callback fence must not rotate generation as though it ran."
        )

        saveGate.release()
        do {
            _ = try await load.value
            XCTFail("The expired automatic owner must abort after its gated save settles.")
        } catch {
            XCTAssertEqual(error as? ProtectionLifecycleMutationFenceError, .ownershipLost)
        }

        let restart = try XCTUnwrap(claimRestartLikeProduction())
        XCTAssertEqual(restart.owner, .explicitRestart)
        XCTAssertEqual(try leaseStore.currentExternalRestartGeneration(), "restart")
    }

    func testOwnedMutationRejectsBusyFenceWithoutBlockingMainActor() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("vpn-lifecycle-fence-busy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fenceURL = directory.appendingPathComponent("mutation.lock")
        let holder = try XCTUnwrap(
            ProtectionLifecycleMutationFence.acquire(lockFileURL: fenceURL, wait: false)
        )
        defer { holder.release() }

        var didRunMutation = false
        do {
            try await ProtectionLifecycleMutationFence.withOwnedMutation(
                lockFileURL: fenceURL,
                validateOwnership: { true },
                operation: {
                    didRunMutation = true
                }
            )
            XCTFail("A busy cross-process fence must reject instead of blocking the MainActor.")
        } catch {
            XCTAssertEqual(error as? ProtectionLifecycleMutationFenceError, .busy)
        }
        XCTAssertFalse(didRunMutation)
    }

    func testDuplicateCleanupRemovesOnlyLavaDuplicatesAndKeepsForeignManagers() async throws {
        let fixture = Fixture()
        let kept = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connected)
        let legacyDuplicate = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .disconnected)
        let foreignVPN = FakeVPNManager(displayName: "Other VPN", bundleID: "com.other.vpn", status: .disconnected)
        fixture.repository.managers = [kept, legacyDuplicate, foreignVPN]

        await fixture.controller.removeDuplicateManagers(keeping: kept)

        XCTAssertTrue(fixture.repository.removedManagers.count == 1)
        XCTAssertTrue(fixture.repository.removedManagers.first === legacyDuplicate)
    }

    func testDuplicateCleanupSkipsWhenKeptManagerIsNotCanonical() async throws {
        let fixture = Fixture()
        let keptLegacy = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .connected)
        let other = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [keptLegacy, other]

        await fixture.controller.removeDuplicateManagers(keeping: keptLegacy)

        XCTAssertTrue(
            fixture.repository.removedManagers.isEmpty,
            "Cleanup only converges on the canonical display name; keeping a legacy manager must not delete siblings."
        )
    }

    func testDuplicateCleanupDoesNotRemoveAfterOwnershipIsLostDuringReload() async {
        let fixture = Fixture()
        let gate = VPNRepositoryLoadGate()
        let kept = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connected)
        let legacyDuplicate = FakeVPNManager(displayName: "Lava Sec", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [kept, legacyDuplicate]
        var ownsLifecycle = true
        fixture.repository.onLoadAll = {
            await gate.wait()
        }

        let cleanup = Task { @MainActor in
            await fixture.controller.removeDuplicateManagers(
                keeping: kept,
                continueIfOwned: { ownsLifecycle }
            )
        }
        await gate.waitUntilStarted()
        ownsLifecycle = false
        gate.release()
        await cleanup.value

        XCTAssertTrue(fixture.repository.removedManagers.isEmpty)
    }

    func testWaitForConnectReturnsImmediatelyWhenAlreadyConnected() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connected)

        var observations: [FakeVPNManager?] = []
        let didConnect = await fixture.controller.waitForConnect(timeout: 5, initialManager: manager) {
            observations.append($0)
        }

        XCTAssertTrue(didConnect)
        XCTAssertEqual(observations.count, 1)
        XCTAssertEqual(fixture.waiter.waitCount, 0)
    }

    func testWaitForConnectObservesTransitionToConnected() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connecting)
        fixture.waiter.onWait = { _ in
            manager.status = .connected
            return true
        }

        var observations: [FakeVPNManager?] = []
        let didConnect = await fixture.controller.waitForConnect(timeout: 5, initialManager: manager) {
            observations.append($0)
        }

        XCTAssertTrue(didConnect)
        XCTAssertEqual(fixture.waiter.waitCount, 1)
        XCTAssertTrue(observations.allSatisfy { $0 === manager })
    }

    func testWaitForConnectTimesOutWhenStatusStaysPending() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connecting)
        fixture.repository.managers = [manager]
        // Each waiter call advances the fake clock past the poll interval; the
        // deadline expires after ~4 polls without any status change.
        fixture.waiter.onWait = { timeout in
            fixture.clock.advance(seconds: max(timeout, 0.5))
            return false
        }

        let didConnect = await fixture.controller.waitForConnect(timeout: 2, initialManager: manager) { _ in }

        XCTAssertFalse(didConnect)
        XCTAssertGreaterThanOrEqual(fixture.waiter.waitCount, 4)
        XCTAssertEqual(fixture.events.last?.0, "wait-for-connect-timeout")
    }

    func testWaitForConnectReloadsManagerWhilePendingAndStopsWhenReloadFindsNone() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .connecting)
        fixture.repository.managers = []
        fixture.waiter.onWait = { _ in
            fixture.clock.advance(seconds: 0.5)
            return false
        }

        var observations: [FakeVPNManager?] = []
        let didConnect = await fixture.controller.waitForConnect(timeout: 5, initialManager: manager) {
            observations.append($0)
        }

        XCTAssertFalse(didConnect, "A reload that finds no manager must end the wait as not connected.")
        XCTAssertFalse(observations.isEmpty)
        XCTAssertTrue((observations.last ?? nil) == nil, "The nil reload observation must reach the caller.")
    }

    func testWaitForConnectToleratesNotYetPendingStatusWithinGraceWindow() async {
        let fixture = Fixture()
        // Right after startVPNTunnel, iOS can briefly still report .disconnected.
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [manager]
        var waits = 0
        fixture.waiter.onWait = { _ in
            waits += 1
            fixture.clock.advance(seconds: 0.5)
            if waits == 1 {
                manager.status = .connecting
            } else if waits >= 3 {
                manager.status = .connected
            }
            return true
        }

        let didConnect = await fixture.controller.waitForConnect(timeout: 10, initialManager: manager) { _ in }

        XCTAssertTrue(
            didConnect,
            "A start that has not transitioned to .connecting yet must be tolerated within the grace window."
        )
    }

    func testWaitForConnectGivesUpAfterGraceWindowWhenStartNeverPends() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [manager]
        fixture.waiter.onWait = { _ in
            fixture.clock.advance(seconds: 0.5)
            return false
        }

        let didConnect = await fixture.controller.waitForConnect(timeout: 30, initialManager: manager) { _ in }

        XCTAssertFalse(didConnect)
        XCTAssertLessThanOrEqual(
            fixture.waiter.waitCount,
            5,
            "A start that never pends must give up after the grace window, not the full timeout."
        )
    }

    func testWaitForStopReturnsImmediatelyWhenAlreadyStopped() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)

        let didStop = await fixture.controller.waitForStop(timeout: 5, initialManager: manager) { _ in }

        XCTAssertTrue(didStop)
        XCTAssertEqual(fixture.waiter.waitCount, 0)
    }

    func testWaitForStopBreaksEarlyOnObservedStatusChange() async {
        let fixture = Fixture()
        let manager = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnecting)
        fixture.waiter.onWait = { _ in
            manager.status = .disconnected
            return true
        }

        let didStop = await fixture.controller.waitForStop(timeout: 5, initialManager: manager) { _ in }

        XCTAssertTrue(didStop)
        XCTAssertEqual(fixture.waiter.waitCount, 1)
        XCTAssertEqual(fixture.events.last?.0, "wait-for-stop-finished")
    }

    func testWaitForStopTimeoutReloadsManagerOnceMoreBeforeGivingUp() async {
        let fixture = Fixture()
        let stuck = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnecting)
        let stopped = FakeVPNManager(displayName: "Lava Security", bundleID: Self.providerBundleID, status: .disconnected)
        fixture.repository.managers = [stuck]
        fixture.waiter.onWait = { timeout in
            fixture.clock.advance(seconds: max(timeout, 0.5))
            return false
        }
        var reloads = 0
        fixture.repository.onLoadAll = {
            reloads += 1
            if reloads >= 4 {
                fixture.repository.managers = [stopped]
            }
        }

        let didStop = await fixture.controller.waitForStop(timeout: 1.5, initialManager: stuck) { _ in }

        XCTAssertTrue(didStop, "The timeout path reloads the manager once more and honors a stop observed there.")
        XCTAssertTrue(fixture.events.contains { $0.0 == "wait-for-stop-timeout-manager-reloaded" })
    }
}

@MainActor
private final class Fixture {
    let repository = FakeVPNManagerRepository()
    let waiter = FakeStatusChangeWaiter()
    let clock = FakeWaitClock()
    private(set) var events: [(String, [String: String])] = []
    private(set) var sleepRequests: [TimeInterval] = []
    private(set) lazy var controller = VPNLifecycleController(
        repository: repository,
        statusWaiter: waiter,
        expectedProviderBundleIdentifier: "com.lavasec.app.tunnel",
        waitPolicy: .init(statusPollInterval: 0.5),
        reloadBeforeCreatePolicy: .init(retryCount: 2, retryDelay: 0.4),
        now: { [clock] in clock.now },
        // Keep retry waits instant and observable in tests.
        sleep: { [weak self] seconds in self?.sleepRequests.append(seconds) },
        emitEvent: { [weak self] event, details in self?.events.append((event, details)) }
    )
}

@MainActor
private final class FakeVPNManager: VPNManagerControlling {
    let displayName: String?
    let bundleID: String?
    var status: ProtectionLifecycleStatus

    init(displayName: String?, bundleID: String?, status: ProtectionLifecycleStatus) {
        self.displayName = displayName
        self.bundleID = bundleID
        self.status = status
    }

    var managerDisplayName: String? { displayName }
    var managerProviderBundleIdentifier: String? { bundleID }
    var lifecycleStatus: ProtectionLifecycleStatus { status }
}

@MainActor
private final class FakeVPNManagerRepository: VPNManagerRepositoryProtocol {
    var managers: [FakeVPNManager] = []
    var onLoadAll: (() async -> Void)?
    var onSaveAndReload: (() async -> Void)?
    private(set) var madeManagers: [FakeVPNManager] = []
    private(set) var configuredManagers: [FakeVPNManager] = []
    private(set) var savedManagers: [FakeVPNManager] = []
    private(set) var removedManagers: [FakeVPNManager] = []



    func loadAll() async throws -> [FakeVPNManager] {
        await onLoadAll?()
        return managers
    }

    func makeManager() -> FakeVPNManager {
        let manager = FakeVPNManager(
            displayName: LavaTunnelConfigurationIdentity.currentDisplayName,
            bundleID: "com.lavasec.app.tunnel",
            status: .disconnected
        )
        madeManagers.append(manager)
        return manager
    }

    func applyConfiguration(to manager: FakeVPNManager) {
        configuredManagers.append(manager)
    }

    func saveAndReload(_ manager: FakeVPNManager) async throws {
        await onSaveAndReload?()
        savedManagers.append(manager)
        if !managers.contains(where: { $0 === manager }) {
            managers.append(manager)
        }
    }

    func remove(_ manager: FakeVPNManager) async throws {
        removedManagers.append(manager)
        managers.removeAll { $0 === manager }
    }
}

private final class VPNLeaseTokenSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: [String]

    init(_ tokens: [String]) {
        self.tokens = tokens
    }

    func next() -> String {
        lock.lock()
        defer { lock.unlock() }
        precondition(!tokens.isEmpty)
        return tokens.removeFirst()
    }
}

@MainActor
private final class VPNRepositoryLoadGate {
    private var started = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        guard !released else { return }
        started = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class FakeStatusChangeWaiter: VPNStatusChangeWaiting {
    var onWait: ((TimeInterval) -> Bool)?
    private(set) var waitCount = 0



    func waitForStatusChange(timeout: TimeInterval) async -> Bool {
        waitCount += 1
        return onWait?(timeout) ?? false
    }
}

@MainActor
private final class FakeWaitClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)



    func advance(seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}
