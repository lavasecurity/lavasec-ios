import Foundation

/// The protection state shared by the Guard screen and external status readers.
public enum ProtectionStatus: Equatable, Sendable {
    /// Protection is deliberately off.
    case off
    /// The profile has not yet been installed.
    case notInstalled
    /// Filtering is temporarily paused until this date.
    case paused(Date)
    /// iOS is starting the tunnel.
    case turningOn
    /// A chained tunnel is still establishing its upstream.
    case establishing
    /// iOS is stopping the tunnel.
    case turningOff
    /// On-demand protection is waiting for a network.
    case reconnecting
    /// The current chained transport is restoring VPN forwarding.
    case vpnRecovering
    /// The chained tunnel has not demonstrated general traffic forwarding.
    case vpnUnconfirmed
    /// Chaining stopped forwarding; local DNS filtering remains active until an explicit retry.
    case chainingFailed
    /// Setup and handshake are verified; no general forwarded traffic has been observed.
    case tunnelReady
    /// The connected tunnel's current health assessment.
    case connected(ProtectionConnectivitySeverity)
    /// There is no authoritative current observation.
    case unavailable

    public var recommendsReconnect: Bool {
        GuardStatusPresentation(status: self).primaryAction == .reconnect
    }

    public var guardianState: GuardianMascotState {
        GuardStatusPresentation(status: self).mascotState
    }

    /// Applies the Guard screen's precedence without reading or changing lifecycle state.
    public static func resolve(
        lifecycle: ProtectionLifecycleStatus,
        pauseUntil: Date? = nil,
        chainedEstablishing: Bool = false,
        observationUnavailable: Bool = false,
        forwardingUnconfirmed: Bool = false,
        chainedFailure: Bool = false,
        setupReady: Bool = false,
        runtimeCondition: ChainedRuntimeCondition = .normal,
        awaitingOnDemandReconnect: Bool = false,
        connectivity: ProtectionConnectivitySeverity? = nil
    ) -> Self {
        // A failed chain needs the explicit retry action even if a stale pause deadline remains.
        if lifecycle == .connected, let pauseUntil, !chainedFailure { return .paused(pauseUntil) }
        if lifecycle == .connected {
            switch runtimeCondition {
            case .recovering:
                if connectivity == .networkUnavailable { return .connected(.networkUnavailable) }
                if chainedFailure { return .chainingFailed }
                if let connectivity, connectivity == .dnsSlow || connectivity == .needsReconnect {
                    return .connected(connectivity)
                }
                return .vpnRecovering
            case .offline: return .connected(.networkUnavailable)
            case .suspended, .retired: return .unavailable
            case .normal: break
            }
            if connectivity == .networkUnavailable { return .connected(.networkUnavailable) }
            if chainedFailure { return .chainingFailed }
            // A current adverse health report outranks uncertainty and startup presentation.
            if let connectivity, !connectivity.yieldsToUnconfirmedChainedForwarding {
                return .connected(connectivity)
            }
        }
        if lifecycle == .connected, observationUnavailable { return .unavailable }
        if lifecycle == .connected, setupReady {
            guard let connectivity else { return .unavailable }
            return connectivity.yieldsToUnconfirmedChainedForwarding ? .tunnelReady : .connected(connectivity)
        }
        if lifecycle == .connected, chainedEstablishing { return .establishing }
        switch lifecycle {
        case .connected:
            guard let connectivity else { return .unavailable }
            if forwardingUnconfirmed, connectivity.yieldsToUnconfirmedChainedForwarding {
                return .vpnUnconfirmed
            }
            return .connected(connectivity)
        case .connecting, .reasserting: return .turningOn
        case .disconnecting: return .turningOff
        case .invalid: return .notInstalled
        case .disconnected: return awaitingOnDemandReconnect ? .reconnecting : .off
        }
    }
}

/// A fresh, minimal provider reply. Reading it never flushes or repairs persisted state.
public struct ProtectionStatusEvidence: Codable, Sendable {
    /// Time the running provider sampled its state.
    public let sampledAt: Date
    /// Whether the provider still owns a live tunnel lifecycle.
    public let lifecycleIsActive: Bool
    /// The same DNS health input used by the Guard screen.
    public let health: TunnelHealthSnapshot
    /// The running tunnel's cached pause deadline, if any.
    public let pauseUntil: Date?
    /// Whether the provider's live path is chained, independent of saved settings.
    public let isChained: Bool
    /// The live runner identity; nil means no runner is available.
    public let sessionGeneration: UInt64?
    /// General traffic delivered through the current transport, excluding DNS replies.
    public let forwardedBytes: UInt64?
    /// Optional current transport identity; absent on older providers.
    public let transportGeneration: UInt64?
    /// Optional atomically verified setup evidence; absent is never interpreted as ready.
    public let setupReady: Bool?
    public let providerLifecycleID: String?
    public let verificationEpoch: UInt64?
    public let forwardingBaseline: UInt64?
    public let runtimeCondition: ChainedRuntimeCondition?

    /// Creates an observation on the provider's state queue.
    public init(sampledAt: Date, lifecycleIsActive: Bool, health: TunnelHealthSnapshot,
                pauseUntil: Date?, isChained: Bool, sessionGeneration: UInt64?, forwardedBytes: UInt64?,
                transportGeneration: UInt64? = nil, setupReady: Bool? = nil,
                providerLifecycleID: String? = nil, verificationEpoch: UInt64? = nil,
                forwardingBaseline: UInt64 = 0, runtimeCondition: ChainedRuntimeCondition = .normal) {
        self.sampledAt = sampledAt
        self.lifecycleIsActive = lifecycleIsActive
        self.health = health
        self.pauseUntil = pauseUntil
        self.isChained = isChained
        self.sessionGeneration = sessionGeneration
        self.forwardedBytes = forwardedBytes
        self.transportGeneration = transportGeneration
        self.setupReady = setupReady
        self.providerLifecycleID = providerLifecycleID
        self.verificationEpoch = verificationEpoch
        self.forwardingBaseline = forwardingBaseline
        self.runtimeCondition = runtimeCondition
    }

    /// Rejects stale replies, then evaluates the same health and chained-forwarding policies as Guard.
    /// The caller supplies the separately persisted failure marker: DNS-only fallback reports
    /// `isChained == false` even when the user's chained forwarding request has failed.
    public func status(now: Date, chainedFailure: Bool = false) -> ProtectionStatus {
        guard lifecycleIsActive, (0...5).contains(now.timeIntervalSince(sampledAt)) else { return .unavailable }
        let pause = pauseUntil.flatMap { $0 > now ? $0 : nil }
        var chainedState = ChainedConnectLifecyclePolicy.State()
        // This is a local projection only: no returned effect is executed. The provider's
        // start time anchors a closed-app observation to the real connected lifecycle.
        let effects = ChainedConnectLifecyclePolicy.reduce(state: &chainedState,
            event: .statusChanged(.connected, onDemandConfirmed: true, userInitiated: false,
                now: health.startedAt.timeIntervalSinceReferenceDate))
        let session: ChainedRuntimeObservation.Session?
        if let sessionGeneration, let forwardedBytes {
            session = .init(generation: sessionGeneration, forwardedBytes: forwardedBytes,
                transportGeneration: transportGeneration ?? 0, setupReady: setupReady == true,
                providerLifecycleID: providerLifecycleID, verificationEpoch: verificationEpoch,
                forwardingBaseline: forwardingBaseline ?? 0, runtimeCondition: runtimeCondition ?? .normal,
                health: health, healthSampledAt: sampledAt)
        } else { session = nil }
        for case .startSampling(let connection) in effects {
            ChainedConnectLifecyclePolicy.reduce(state: &chainedState,
                event: .observed(connection: connection,
                    observation: isChained ? .chained(session: session) : .dnsOnly,
                    now: now.timeIntervalSinceReferenceDate))
        }
        return .resolve(lifecycle: .connected, pauseUntil: pause,
            chainedEstablishing: chainedState.claim == .establishing,
            observationUnavailable: chainedState.claim == .checking,
            forwardingUnconfirmed: chainedState.claim == .unconfirmed,
            chainedFailure: chainedFailure,
            setupReady: chainedState.setupReady,
            runtimeCondition: runtimeCondition ?? .normal,
            connectivity: ProtectionConnectivityPolicy.assessment(isConnected: true, health: health, now: now).severity)
    }
}

/// Failures at the external protection-command boundary.
public enum ProtectionShortcutError: Error, Equatable, Sendable {
    /// Another protection operation is running.
    case busy
    /// Existing Lava authentication was not satisfied.
    case authenticationRequired
    /// The lifecycle handled a start failure and published an error to the app.
    case startFailed
}

/// Serializes explicit connect/disconnect requests through the app's existing action gate.
public enum ProtectionShortcutCoordinator {
    /// Adapts the lifecycle's completion flag and separately published error for Shortcuts.
    /// A completed operation may still have handled a setup, persistence, or tunnel-start failure.
    public static func validateStartResult(completed: Bool, hasError: Bool) throws {
        guard !hasError else { throw ProtectionShortcutError.startFailed }
        guard completed else { throw CancellationError() }
    }

    /// Authorizes before reading the action state; a repeat never reverses the requested direction.
    @MainActor
    public static func perform(
        enabled: Bool,
        gate: ProtectionActionOrchestrator,
        authorize: () async throws -> Bool,
        readState: () async throws -> (ProtectionLifecycleStatus, Bool),
        accept: () async throws -> Void = {},
        connect: () async throws -> Void,
        resume: () async throws -> Void,
        disconnect: () async throws -> Void
    ) async throws {
        let kind: ProtectionActionKind = enabled ? .turnOn : .turnOff
        guard gate.claim(kind) else { throw ProtectionShortcutError.busy }
        defer { gate.release(kind) }
        guard try await authorize() else { throw ProtectionShortcutError.authenticationRequired }
        try Task.checkCancellation()
        let (status, paused) = try await readState()
        try Task.checkCancellation()
        if enabled, status == .disconnecting { throw ProtectionShortcutError.busy }
        try await accept()
        if !enabled {
            // Even an already-disconnected profile can have armed on-demand rules or an
            // outstanding restore. The existing stop path persists OFF and disarms both.
            try await disconnect()
        } else if status == .connected {
            if paused { try await resume() }
        } else if !ProtectionLifecyclePolicy.isStartPending(status) {
            try await connect()
        }
    }
}
