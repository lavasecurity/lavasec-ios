import Dispatch
import Foundation
import LavaSecKit

/// Resolver-health values read by provider scheduling and runtime guards.
///
/// This immutable view exposes no mutation surface for the coordinator's three
/// evidence lifetimes.
public struct ResolverHealthSchedulingView: Equatable, Sendable {
    /// Whether the most recently observed network path is satisfied.
    public let networkPathIsSatisfied: Bool
    /// Consecutive upstream failures in the current network episode.
    public let consecutiveUpstreamFailureCount: Int
    /// Consecutive failed smoke probes in the current network episode.
    public let consecutiveSmokeProbeFailureCount: Int
    /// Consecutive rejected smoke responses scoped to the primary identity.
    public let consecutiveRejectedResponseCount: Int
    /// Consecutive observations supporting Device DNS fallback activation.
    public let deviceDNSFallbackEvidenceCount: Int
    /// Whether Device DNS fallback mode is currently active.
    public let deviceDNSFallbackModeActive: Bool
    /// The latest accepted primary evidence eligible to skip a routine probe.
    public let lastAcceptedPrimaryEvidenceAt: Date?
    /// Whether a reconnect-needed episode is currently active.
    public let reconnectEpisodeIsActive: Bool
}

/// Opaque ownership token for one in-flight resolver smoke probe.
public struct ResolverSmokeProbeToken: Equatable, Hashable, Sendable {
    fileprivate let generation: UInt64
}

/// One smoke-probe admission with its opaque owner and canary rotation sequence.
public struct ResolverSmokeProbeStart: Equatable, Sendable {
    /// The only token allowed to complete this probe.
    public let token: ResolverSmokeProbeToken
    /// The sequence used to rotate the probe domain.
    public let rotationSequence: Int
}

/// A resolver-health transition ready for synchronous provider projection and effects.
public struct ResolverHealthCoordinatorTransition: Equatable, Sendable {
    /// The field-wise patch for reducer-owned snapshot fields.
    public let projection: ResolverHealthGatewayProjection
    /// Side effects to execute in the emitted order after projection.
    public let effects: [ResolverHealthGatewayEffect]

    init(_ transition: ResolverHealthGatewayTransition) {
        projection = transition.projection
        effects = transition.effects
    }
}

/// Owns resolver-health evidence and smoke-probe fencing on a caller-supplied serial queue.
///
/// The queue is also the actor executor, so callers already on that queue can use
/// `assumeIsolated` and preserve synchronous projection/effect ordering.
public actor ResolverHealthCoordinator {
    private nonisolated let queue: DispatchSerialQueue
    private var state: ResolverHealthEvidenceState
    private var smokeProbeGeneration: UInt64 = 0
    private var currentSmokeProbeToken: ResolverSmokeProbeToken?

    /// The serial queue that executes every actor-isolated transition.
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        queue.asUnownedSerialExecutor()
    }

    /// Creates an empty coordinator whose transitions execute on `queue`.
    ///
    /// - Parameter queue: The serial queue callers must occupy before synchronous
    ///   `assumeIsolated` access.
    public init(queue: DispatchSerialQueue) {
        self.queue = queue
        state = ResolverHealthEvidenceState()
    }

    init(queue: DispatchSerialQueue, state: ResolverHealthEvidenceState) {
        self.queue = queue
        self.state = state
    }

    /// Starts a probe, superseding every prior probe owner.
    public func beginSmokeProbe() -> ResolverSmokeProbeStart {
        smokeProbeGeneration &+= 1
        let token = ResolverSmokeProbeToken(generation: smokeProbeGeneration)
        currentSmokeProbeToken = token
        return ResolverSmokeProbeStart(
            token: token,
            rotationSequence: Int(truncatingIfNeeded: smokeProbeGeneration)
        )
    }

    /// Applies a smoke completion only when `token` is current, then retires it.
    ///
    /// - Returns: The resulting transition, or `nil` when the token is stale or
    ///   has already completed.
    public func completeSmokeProbe(
        _ completion: ResolverHealthSmokeProbeCompletion,
        token: ResolverSmokeProbeToken,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthCoordinatorTransition? {
        guard currentSmokeProbeToken == token else {
            return nil
        }
        advanceSmokeProbeFence()
        return reduce(
            .smokeProbeCompleted(completion),
            projectingOnto: snapshot
        )
    }

    /// Retires the current probe and advances the fence without changing evidence.
    public func invalidateInFlightSmokeProbe() {
        advanceSmokeProbeFence()
    }

    /// Reduces one non-smoke resolver-health event and retains its resulting evidence state.
    public func apply(
        _ event: ResolverHealthGatewayEvent,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthCoordinatorTransition {
        precondition(
            !event.requiresSmokeProbeToken,
            "Smoke-probe completion must use completeSmokeProbe(_:token:projectingOnto:)"
        )
        if event.resetsResolverHealthLifecycle {
            advanceSmokeProbeFence()
        }
        return reduce(event, projectingOnto: snapshot)
    }

    /// Current immutable values needed by provider scheduling and runtime guards.
    public var schedulingView: ResolverHealthSchedulingView {
        ResolverHealthSchedulingView(
            networkPathIsSatisfied: state.session.networkPathIsSatisfied,
            consecutiveUpstreamFailureCount: state.episode.consecutiveUpstreamFailureCount,
            consecutiveSmokeProbeFailureCount: state.episode.consecutiveSmokeProbeFailureCount,
            consecutiveRejectedResponseCount: state.identity.rejectedResponseCount,
            deviceDNSFallbackEvidenceCount: state.episode.deviceDNSFallbackEvidenceCount,
            deviceDNSFallbackModeActive: state.episode.deviceDNSFallbackModeActive,
            lastAcceptedPrimaryEvidenceAt: state.episode.lastAcceptedPrimaryEvidenceAt,
            reconnectEpisodeIsActive: state.reconnectEpisode != nil
        )
    }

    private func advanceSmokeProbeFence() {
        smokeProbeGeneration &+= 1
        currentSmokeProbeToken = nil
    }

    private func reduce(
        _ event: ResolverHealthGatewayEvent,
        projectingOnto snapshot: TunnelHealthSnapshot
    ) -> ResolverHealthCoordinatorTransition {
        let reduction = ResolverHealthGateway.reduce(
            state: state,
            event: event,
            projectingOnto: snapshot
        )
        state = reduction.state
        return ResolverHealthCoordinatorTransition(reduction.transition)
    }
}
