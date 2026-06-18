import XCTest
@testable import LavaSecCore

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
    var onLoadAll: (() -> Void)?
    private(set) var madeManagers: [FakeVPNManager] = []
    private(set) var configuredManagers: [FakeVPNManager] = []
    private(set) var savedManagers: [FakeVPNManager] = []
    private(set) var removedManagers: [FakeVPNManager] = []



    func loadAll() async throws -> [FakeVPNManager] {
        onLoadAll?()
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
