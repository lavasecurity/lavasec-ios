import Foundation

/// Minimal VPN manager state needed for lifecycle selection and status waits.
///
/// The app target supplies the NetworkExtension-backed conformance so platform types remain out of
/// this package and lifecycle behavior stays executable with deterministic fakes.

@MainActor
public protocol VPNManagerControlling: AnyObject {
    /// Human-readable profile name used to select the canonical Lava manager.
    var managerDisplayName: String? { get }
    /// Provider identifier used to reject unrelated system VPN profiles.
    var managerProviderBundleIdentifier: String? { get }
    /// Current normalized tunnel lifecycle state.
    var lifecycleStatus: ProtectionLifecycleStatus { get }
}

/// Persistence operations needed to load, configure, save, and remove VPN managers.
@MainActor
public protocol VPNManagerRepositoryProtocol {
    /// Platform-specific manager type controlled by this repository.
    associatedtype Manager: VPNManagerControlling

    /// Loads every saved VPN manager visible to the application.
    func loadAll() async throws -> [Manager]
    /// Creates an unsaved manager instance.
    func makeManager() -> Manager
    /// Applies the current Lava configuration to a manager before persistence.
    func applyConfiguration(to manager: Manager)
    /// Saves a manager and reloads its canonical preference state.
    func saveAndReload(_ manager: Manager) async throws
    /// Removes a manager from system preferences.
    func remove(_ manager: Manager) async throws
}

/// Waits for system tunnel-status notifications without exposing NetworkExtension types.
@MainActor
public protocol VPNStatusChangeWaiting {
    /// Waits up to `timeout` for a status-change signal and reports whether one arrived.
    func waitForStatusChange(timeout: TimeInterval) async -> Bool
}

/// Signals that an async manager mutation lost its caller-owned lifecycle fence while suspended.
public enum VPNLifecycleMutationError: Error, Equatable, Sendable {
    /// Caller ownership changed while an asynchronous preference mutation was suspended.
    case superseded
}

extension ProtectionLifecycleStatus {
    /// Stable diagnostic label for analytics emitted by the lifecycle controller.
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

/// Selects and mutates Lava VPN managers while preserving caller-owned lifecycle fencing.
@MainActor
public final class VPNLifecycleController<Repository: VPNManagerRepositoryProtocol> {
    /// Platform-specific manager type supplied by the repository.
    public typealias Manager = Repository.Manager

    /// Timing used while observing connect and stop transitions.
    public struct WaitPolicy: Sendable {
        /// Maximum interval between status observations.
        public let statusPollInterval: TimeInterval
        /// Grace period tolerating a briefly non-pending status immediately after tunnel start.
        public let startGraceInterval: TimeInterval

        /// Creates wait timing with production polling and post-start grace defaults.
        public init(statusPollInterval: TimeInterval = 0.5, startGraceInterval: TimeInterval = 2) {
            self.statusPollInterval = statusPollInterval
            self.startGraceInterval = startGraceInterval
        }
    }

    /// Retry policy for transient empty preference loads before creating a replacement profile.
    ///
    /// iOS can briefly report no managers after extension teardown or a network handoff even while
    /// the saved profile still exists. Re-querying prevents a duplicate profile and permission prompt.
    public struct ReloadBeforeCreatePolicy: Sendable {
        /// Number of additional loads after the first empty result.
        public let retryCount: Int
        /// Delay between empty-result retries.
        public let retryDelay: TimeInterval

        /// Creates a transient-empty retry policy.
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

    /// Creates a controller over platform persistence, status waiting, timing, and event seams.
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

    /// Loads the highest-priority existing Lava manager from the current preference snapshot.
    public func loadExistingManager() async throws -> Manager? {
        try await matchingManagers().first
    }

    /// Loads Lava-owned managers ordered by active status and then canonical display name.
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

    /// Resolves or creates the canonical manager, saves it, and removes stale Lava duplicates.
    ///
    /// `continueIfOwned` is checked across every suspension. `performPreferenceMutation` lets a
    /// caller keep each non-cancellable platform save/removal inside its already-owned lifecycle
    /// fence; a failed ownership check throws `VPNLifecycleMutationError.superseded`.
    public func loadOrCreateManager(
        existing: Manager? = nil,
        continueIfOwned: @escaping @MainActor () -> Bool = { true },
        performPreferenceMutation: @escaping (
            @escaping @MainActor () async throws -> Void
        ) async throws -> Void = { operation in
            try await operation()
        }
    ) async throws -> Manager {
        let current = try await resolveManagerBeforeCreate(existing: existing)
        guard continueIfOwned() else {
            throw VPNLifecycleMutationError.superseded
        }
        let manager = current ?? repository.makeManager()
        if current == nil {
            emitEvent("load-or-create-creating-new-manager", [:])
        }
        repository.applyConfiguration(to: manager)
        try await performPreferenceMutation {
            try await self.repository.saveAndReload(manager)
        }
        guard continueIfOwned() else {
            throw VPNLifecycleMutationError.superseded
        }
        try await removeDuplicateManagers(
            keeping: manager,
            continueIfOwned: continueIfOwned,
            performPreferenceMutation: performPreferenceMutation
        )
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

    /// Removes one manager directly from the repository.
    public func removeManager(_ manager: Manager) async throws {
        try await repository.remove(manager)
    }

    /// Best-effort removal of noncanonical Lava managers while caller ownership remains current.
    ///
    /// Repository failures are tolerated, but loss of `continueIfOwned` stops further removal.
    public func removeDuplicateManagers(
        keeping kept: Manager,
        continueIfOwned: @escaping @MainActor () -> Bool = { true }
    ) async {
        try? await removeDuplicateManagers(
            keeping: kept,
            continueIfOwned: continueIfOwned,
            performPreferenceMutation: { operation in
                try await operation()
            }
        )
    }

    private func removeDuplicateManagers(
        keeping kept: Manager,
        continueIfOwned: @escaping @MainActor () -> Bool,
        performPreferenceMutation: @escaping (
            @escaping @MainActor () async throws -> Void
        ) async throws -> Void
    ) async throws {
        guard kept.managerDisplayName == LavaTunnelConfigurationIdentity.currentDisplayName else {
            return
        }

        guard continueIfOwned() else {
            throw VPNLifecycleMutationError.superseded
        }
        guard let managers = try? await repository.loadAll() else {
            return
        }
        guard continueIfOwned() else {
            throw VPNLifecycleMutationError.superseded
        }

        for manager in managers where manager.managerDisplayName != LavaTunnelConfigurationIdentity.currentDisplayName {
            guard LavaTunnelConfigurationIdentity.matches(
                displayName: manager.managerDisplayName,
                providerBundleIdentifier: manager.managerProviderBundleIdentifier,
                expectedProviderBundleIdentifier: expectedProviderBundleIdentifier
            ) else {
                continue
            }

            guard continueIfOwned() else {
                throw VPNLifecycleMutationError.superseded
            }
            do {
                try await performPreferenceMutation {
                    try await self.repository.remove(manager)
                }
            } catch let error as ProtectionLifecycleMutationFenceError {
                throw error
            } catch {
                // Duplicate removal stays best-effort. A repository failure cannot make the
                // canonical manager unsafe; a lifecycle-fence failure above must abort instead.
            }
        }
    }

    /// Waits for the live connection to reach `.connected` before timeout or a terminal state.
    ///
    /// Every observation, including reloads that produce `nil`, is sent to `onObservation` so the
    /// caller can keep its cached manager and published status synchronized.
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

    /// Waits until the live connection is no longer stopping, reloading once after timeout.
    ///
    /// Every observation is sent to `onObservation`; the result is `false` only when the final
    /// reloaded status remains stop-pending.
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
