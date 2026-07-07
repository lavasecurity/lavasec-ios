import Foundation

// Abstractions over NETunnelProviderManager so VPN manager lifecycle behavior
// (selection, save/reload, duplicate cleanup, status waits) is testable with
// fakes. The app target provides NetworkExtension-backed conformances; per the
// plan's architecture decisions, NetworkExtension types stay out of this module.

@MainActor
public protocol VPNManagerControlling: AnyObject {
    var managerDisplayName: String? { get }
    var managerProviderBundleIdentifier: String? { get }
    var lifecycleStatus: ProtectionLifecycleStatus { get }
}

@MainActor
public protocol VPNManagerRepositoryProtocol {
    associatedtype Manager: VPNManagerControlling

    func loadAll() async throws -> [Manager]
    func makeManager() -> Manager
    func applyConfiguration(to manager: Manager)
    func saveAndReload(_ manager: Manager) async throws
    func remove(_ manager: Manager) async throws
}

@MainActor
public protocol VPNStatusChangeWaiting {
    // Waits up to `timeout` for a status-change signal; true when a change was
    // observed before the timeout elapsed.
    func waitForStatusChange(timeout: TimeInterval) async -> Bool
}

extension ProtectionLifecycleStatus {
    public var debugLabel: String {
        switch self {
        case .invalid: "invalid"
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .connected: "connected"
        case .reasserting: "reasserting"
        case .disconnecting: "disconnecting"
        }
    }
}

@MainActor
public final class VPNLifecycleController<Repository: VPNManagerRepositoryProtocol> {
    public typealias Manager = Repository.Manager

    public struct WaitPolicy: Sendable {
        public let statusPollInterval: TimeInterval
        // Right after startVPNTunnel the connection can still read a
        // non-pending status (.disconnected/.invalid) for a beat; the connect
        // wait tolerates that for this long instead of giving up immediately.
        public let startGraceInterval: TimeInterval

        public init(statusPollInterval: TimeInterval = 0.5, startGraceInterval: TimeInterval = 2) {
            self.statusPollInterval = statusPollInterval
            self.startGraceInterval = startGraceInterval
        }
    }

    // iOS's loadAllFromPreferences can transiently return an empty list right
    // after the extension is torn down or during a network handoff, even though
    // the saved profile still exists. Re-querying a few times before concluding
    // "no profile" avoids minting a brand-new manager in that window — which
    // re-prompts for VPN permission and leaves a duplicate profile (the
    // "asked to install a new VPN profile after a network change" regression).
    public struct ReloadBeforeCreatePolicy: Sendable {
        public let retryCount: Int
        public let retryDelay: TimeInterval

        public init(retryCount: Int = 2, retryDelay: TimeInterval = 0.4) {
            self.retryCount = retryCount
            self.retryDelay = retryDelay
        }
    }

    private let repository: Repository
    private let statusWaiter: any VPNStatusChangeWaiting
    private let expectedProviderBundleIdentifier: String
    private let waitPolicy: WaitPolicy
    private let reloadBeforeCreatePolicy: ReloadBeforeCreatePolicy
    private let now: @MainActor () -> Date
    private let sleep: @MainActor (TimeInterval) async -> Void
    private let emitEvent: @MainActor (String, [String: String]) -> Void

    public init(
        repository: Repository,
        statusWaiter: any VPNStatusChangeWaiting,
        expectedProviderBundleIdentifier: String,
        waitPolicy: WaitPolicy = WaitPolicy(),
        reloadBeforeCreatePolicy: ReloadBeforeCreatePolicy = ReloadBeforeCreatePolicy(),
        now: @escaping @MainActor () -> Date = { Date() },
        sleep: @escaping @MainActor (TimeInterval) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
        },
        emitEvent: @escaping @MainActor (String, [String: String]) -> Void = { _, _ in }
    ) {
        self.repository = repository
        self.statusWaiter = statusWaiter
        self.expectedProviderBundleIdentifier = expectedProviderBundleIdentifier
        self.waitPolicy = waitPolicy
        self.reloadBeforeCreatePolicy = reloadBeforeCreatePolicy
        self.now = now
        self.sleep = sleep
        self.emitEvent = emitEvent
    }

    public func loadExistingManager() async throws -> Manager? {
        try await matchingManagers().first
    }

    // Lava-owned managers, preferring the active one, then the canonical
    // display name (so duplicate cleanup converges on the right survivor).
    public func matchingManagers() async throws -> [Manager] {
        try await repository.loadAll()
            .filter { manager in
                LavaTunnelConfigurationIdentity.matches(
                    displayName: manager.managerDisplayName,
                    providerBundleIdentifier: manager.managerProviderBundleIdentifier,
                    expectedProviderBundleIdentifier: expectedProviderBundleIdentifier
                )
            }
            .sorted { selectionPriority($0) < selectionPriority($1) }
    }

    public func loadOrCreateManager(existing: Manager? = nil) async throws -> Manager {
        let current = try await resolveManagerBeforeCreate(existing: existing)
        let manager = current ?? repository.makeManager()
        if current == nil {
            emitEvent("load-or-create-creating-new-manager", [:])
        }
        repository.applyConfiguration(to: manager)
        try await repository.saveAndReload(manager)
        await removeDuplicateManagers(keeping: manager)
        return manager
    }

    // Resolve the existing Lava manager before falling back to creating one.
    // A passed-in `existing` is trusted as-is; otherwise we re-query, tolerating
    // a transient empty load (see ReloadBeforeCreatePolicy) so a network handoff
    // can't trick us into minting a duplicate profile and re-prompting for VPN
    // permission. A thrown load error propagates (we never create over an error).
    private func resolveManagerBeforeCreate(existing: Manager?) async throws -> Manager? {
        if let existing {
            return existing
        }

        var attempt = 0
        while true {
            if let found = try await loadExistingManager() {
                if attempt > 0 {
                    emitEvent("load-existing-manager-recovered-after-empty", ["attempts": "\(attempt + 1)"])
                }
                return found
            }

            guard attempt < reloadBeforeCreatePolicy.retryCount else {
                return nil
            }

            attempt += 1
            emitEvent("load-existing-manager-empty-retry", ["attempt": "\(attempt)"])
            await sleep(reloadBeforeCreatePolicy.retryDelay)
        }
    }

    public func removeManager(_ manager: Manager) async throws {
        try await repository.remove(manager)
    }

    public func removeDuplicateManagers(keeping kept: Manager) async {
        guard kept.managerDisplayName == LavaTunnelConfigurationIdentity.currentDisplayName else {
            return
        }

        guard let managers = try? await repository.loadAll() else {
            return
        }

        for manager in managers where manager.managerDisplayName != LavaTunnelConfigurationIdentity.currentDisplayName {
            guard LavaTunnelConfigurationIdentity.matches(
                displayName: manager.managerDisplayName,
                providerBundleIdentifier: manager.managerProviderBundleIdentifier,
                expectedProviderBundleIdentifier: expectedProviderBundleIdentifier
            ) else {
                continue
            }

            try? await repository.remove(manager)
        }
    }

    // Waits for the manager's live connection status to reach .connected.
    // Every observation (including reloads that may yield nil) flows through
    // onObservation so the caller can keep its published state current.
    public func waitForConnect(
        timeout: TimeInterval,
        initialManager: Manager?,
        onObservation: (Manager?) -> Void
    ) async -> Bool {
        var current = initialManager
        onObservation(current)
        var status = current?.lifecycleStatus ?? .invalid
        guard status != .connected else {
            return true
        }

        emitEvent("wait-for-connect-begin", [
            "timeout": "\(timeout)",
            "vpnStatus": status.debugLabel
        ])

        let startedAt = now()
        let deadline = startedAt.addingTimeInterval(timeout)
        while status != .connected {
            // Non-pending states end the wait once the grace window passed:
            // before that, iOS may simply not have transitioned the freshly
            // requested start into .connecting yet.
            if !ProtectionLifecyclePolicy.isStartPending(status),
               now().timeIntervalSince(startedAt) >= waitPolicy.startGraceInterval {
                break
            }

            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else {
                break
            }

            _ = await statusWaiter.waitForStatusChange(timeout: min(waitPolicy.statusPollInterval, remaining))
            onObservation(current)
            status = current?.lifecycleStatus ?? .invalid
            if status != .connected, ProtectionLifecyclePolicy.isStartPending(status) {
                current = try? await loadExistingManager()
                onObservation(current)
                status = current?.lifecycleStatus ?? .invalid
            }
        }

        let didConnect = status == .connected
        emitEvent(didConnect ? "wait-for-connect-finished" : "wait-for-connect-timeout", [
            "vpnStatus": status.debugLabel
        ])
        return didConnect
    }

    @discardableResult
    public func waitForStop(
        timeout: TimeInterval,
        initialManager: Manager?,
        onObservation: (Manager?) -> Void
    ) async -> Bool {
        var current = initialManager
        onObservation(current)
        var status = current?.lifecycleStatus ?? .invalid
        guard ProtectionLifecyclePolicy.isStopPending(status) else {
            return true
        }

        emitEvent("wait-for-stop-begin", [
            "timeout": "\(timeout)",
            "vpnStatus": status.debugLabel
        ])

        let deadline = now().addingTimeInterval(timeout)
        while ProtectionLifecyclePolicy.isStopPending(status) {
            let remaining = deadline.timeIntervalSince(now())
            guard remaining > 0 else {
                break
            }

            let observedStatusChange = await statusWaiter.waitForStatusChange(
                timeout: min(waitPolicy.statusPollInterval, remaining)
            )
            onObservation(current)
            status = current?.lifecycleStatus ?? .invalid
            if ProtectionLifecyclePolicy.isStopPending(status) {
                current = try? await loadExistingManager()
                onObservation(current)
                status = current?.lifecycleStatus ?? .invalid
            }
            if observedStatusChange, !ProtectionLifecyclePolicy.isStopPending(status) {
                break
            }
        }

        if ProtectionLifecyclePolicy.isStopPending(status) {
            current = try? await loadExistingManager()
            onObservation(current)
            status = current?.lifecycleStatus ?? .invalid
            emitEvent("wait-for-stop-timeout-manager-reloaded", [
                "vpnStatus": status.debugLabel
            ])
        }

        let didStop = !ProtectionLifecyclePolicy.isStopPending(status)
        emitEvent(didStop ? "wait-for-stop-finished" : "wait-for-stop-timeout", [
            "vpnStatus": status.debugLabel
        ])
        return didStop
    }

    private func selectionPriority(_ manager: Manager) -> Int {
        let activePriority = ProtectionLifecyclePolicy.isProtectionEnabled(manager.lifecycleStatus) ? 0 : 10
        let displayNamePriority = LavaTunnelConfigurationIdentity.displayNamePriority(manager.managerDisplayName)
        return activePriority + displayNamePriority
    }
}
