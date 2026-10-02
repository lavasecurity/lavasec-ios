import Foundation

/// Collects the DNS patch's actual physical endpoints before the first route installation,
/// then drains changes arriving during that installation without concurrent settings posts.
public struct DNSPatchStartupInstallPolicy: Sendable {
    /// Whether an observation needs an ordinary post-startup settings update.
    public enum ObservationAction: Equatable, Sendable {
        case ignore
        case retain
        case reapply
    }

    /// The next step before admitting the initial settings snapshot.
    public enum PreparationAction: Equatable, Sendable {
        /// The request belongs to a stale, cancelled, or already-admitted preparation.
        case ignore
        /// Keep the cancellable preparation completion until physical discovery settles.
        case waitForDiscovery
        /// Fail startup without posting settings after physical discovery failed.
        case discoveryFailed(DNSPatchInitialDiscoveryPolicy.Failure)
        /// Physical discovery succeeded; the initial settings snapshot may be captured.
        case ready
    }

    /// The next step after one startup settings installation succeeds.
    public enum InstallAction: Equatable, Sendable {
        /// The callback cannot settle the current startup installation.
        case ignore
        /// Install the latest route/settings snapshot before reporting startup readiness.
        case installLatest
        /// Every retained startup change is installed, so startup may report readiness.
        case ready
    }

    private enum Phase: Sendable {
        case collecting
        case installing
        case ready
        case cancelled
    }

    private let lifecycleGeneration: UInt64
    private let contract: DNSPatchContract
    private var phase: Phase = .collecting
    private var latestObservedEndpoints: [String] = []
    private var installingObservedEndpoints: [String] = []
    private var initialDiscoveryCompletion: DNSPatchInitialDiscoveryPolicy.Completion?
    private var settingsReapplyIsPending = false

    /// Begins collecting physical observations for one provider lifecycle.
    public init(contract: DNSPatchContract, lifecycleGeneration: UInt64) {
        self.contract = contract
        self.lifecycleGeneration = lifecycleGeneration
    }

    /// Admits the first settings snapshot only after bounded physical discovery succeeds.
    /// Unknown or failed discovery cannot authorize routes, including on nonstandard Pref64 networks.
    public mutating func initialSettingsAction(lifecycleGeneration: UInt64) -> PreparationAction {
        guard self.lifecycleGeneration == lifecycleGeneration, phase == .collecting else { return .ignore }
        guard let initialDiscoveryCompletion else { return .waitForDiscovery }
        if case .failed(let failure) = initialDiscoveryCompletion {
            cancel()
            return .discoveryFailed(failure)
        }
        return .ready
    }

    /// Retains startup observations; after readiness only changed capture membership
    /// asks for a reapply. At most eight endpoints are retained, matching the contract.
    /// Stale lifecycles and cancellation cannot change the baseline.
    @discardableResult
    public mutating func observeEndpoints(_ addresses: [String], lifecycleGeneration: UInt64) -> ObservationAction {
        guard self.lifecycleGeneration == lifecycleGeneration, phase != .cancelled else { return .ignore }
        let boundedAddresses = Array(addresses.prefix(8))
        let changed = contract.requiresRouteUpdate(
            previousObservedEndpoints: latestObservedEndpoints, observedEndpoints: boundedAddresses)
        latestObservedEndpoints = boundedAddresses
        return phase == .ready && changed ? .reapply : .retain
    }

    /// Serializes ordinary path, configuration, and filter nudges with startup settings.
    /// Before the first snapshot, its current path/configuration absorbs the request. Once an
    /// install is in flight, retain one latest refresh even when DNS destinations do not change.
    @discardableResult
    public mutating func requestSettingsReapply(lifecycleGeneration: UInt64) -> ObservationAction {
        guard self.lifecycleGeneration == lifecycleGeneration, phase != .cancelled else { return .ignore }
        switch phase {
        case .ready: return .reapply
        case .collecting: return .retain
        case .installing:
            settingsReapplyIsPending = true
            return .retain
        case .cancelled: return .ignore
        }
    }

    /// Captures the exact observations used by the initial settings bundle. The owner
    /// calls this after discovery succeeds, while building the bundle in one serialized operation.
    @discardableResult
    public mutating func beginInitialInstall(lifecycleGeneration: UInt64) -> Bool {
        guard self.lifecycleGeneration == lifecycleGeneration, phase == .collecting,
              initialDiscoveryCompletion == .succeeded else { return false }
        installingObservedEndpoints = latestObservedEndpoints
        settingsReapplyIsPending = false
        phase = .installing
        return true
    }

    /// Records one explicit initial-discovery result. The provider separately consumes
    /// any retained wait completion; early results are remembered before initial settings admission.
    @discardableResult
    public mutating func initialDiscoveryDidComplete(
        _ completion: DNSPatchInitialDiscoveryPolicy.Completion, lifecycleGeneration: UInt64
    ) -> Bool {
        guard self.lifecycleGeneration == lifecycleGeneration, phase == .collecting,
              initialDiscoveryCompletion == nil else { return false }
        initialDiscoveryCompletion = completion
        return true
    }

    /// Settles one successful install, draining route changes and ordinary settings nudges.
    /// Initial discovery has already succeeded before any settings snapshot is admitted.
    public mutating func settingsInstallDidComplete(lifecycleGeneration: UInt64) -> InstallAction {
        guard self.lifecycleGeneration == lifecycleGeneration, phase == .installing else { return .ignore }
        if settingsReapplyIsPending || contract.requiresRouteUpdate(previousObservedEndpoints: installingObservedEndpoints,
            observedEndpoints: latestObservedEndpoints) {
            installingObservedEndpoints = latestObservedEndpoints
            settingsReapplyIsPending = false
            phase = .installing
            return .installLatest
        }
        phase = .ready
        return .ready
    }

    /// Discards pending work after an install failure, stop, or lifecycle invalidation.
    public mutating func cancel() {
        phase = .cancelled
        latestObservedEndpoints = []
        installingObservedEndpoints = []
        initialDiscoveryCompletion = nil
        settingsReapplyIsPending = false
    }
}
