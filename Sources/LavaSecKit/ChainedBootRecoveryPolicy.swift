import Foundation

/// Retries a protected-storage startup refusal after first unlock, without a restart loop.
///
/// The boot lifecycle keeps its DNS-only path while waiting. A new start after the recovery
/// cannot re-arm this policy because protected data is already readable. Plan: LAV-124,
/// lavasec-infra `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`.
public struct ChainedBootRecoveryPolicy: Sendable {
    /// Cheap pre-unlock and active-window probing cadence; dormancy has no timer.
    public static let pollInterval: TimeInterval = 5
    /// Bounds each online readiness window, including an uncancellable Keychain call.
    public static let recoveryWindow: TimeInterval = 60
    /// The maximum fresh readiness reads; only a successful read permits a restart.
    public static let maxReadinessChecks = 3

    /// At most three online windows; only a genuine combined-path edge opens a successor.
    public static let maxOnlineWindows = 3

    /// Current lifecycle, storage, user-intent and relaunch facts, sampled by the caller.
    public struct Context: Sendable {
        /// The current provider lifecycle, compared with the captured boot lifecycle.
        public var generation: UInt64
        /// Whether startup completed and this lifecycle still serves packets.
        public var lifecycleIsActive: Bool
        /// The refusal owned by the current lifecycle, rather than a prior latch.
        public var refusal: TunnelDataPathLatch.Refusal?
        /// Fresh protected-content readability, never file metadata alone.
        public var protectedDataIsReadable: Bool
        /// The durable explicit direction, with the legacy fallback only on absence.
        public var protectionIsWanted: Bool
        /// Whether the fresh configuration still requests and permits VPN chaining.
        public var chainingIsEnabled: Bool
        /// Confirmed on-demand recovery; cancellation requires a relaunch guarantee.
        public var onDemandIsEnabled: Bool
        /// Whether both the delivered physical path and health report are viable.
        public var networkIsSatisfied: Bool
        /// Serial of genuine unsatisfied-to-satisfied transitions of the delivered combined gate.
        public var networkTransitionSerial: UInt64
        /// Any uncancellable readiness read, including one from an older lifecycle.
        public var physicalReadIsInFlight: Bool
        /// Monotonic time in seconds, never a settable wall clock.
        public var now: TimeInterval

        /// Creates an observation without defaults for the safety-critical gates.
        public init(generation: UInt64, lifecycleIsActive: Bool,
                    refusal: TunnelDataPathLatch.Refusal?, protectedDataIsReadable: Bool,
                    protectionIsWanted: Bool, chainingIsEnabled: Bool,
                    onDemandIsEnabled: Bool, networkIsSatisfied: Bool,
                    networkTransitionSerial: UInt64, physicalReadIsInFlight: Bool, now: TimeInterval) {
            self.generation = generation
            self.lifecycleIsActive = lifecycleIsActive
            self.refusal = refusal
            self.protectedDataIsReadable = protectedDataIsReadable
            self.protectionIsWanted = protectionIsWanted
            self.chainingIsEnabled = chainingIsEnabled
            self.onDemandIsEnabled = onDemandIsEnabled
            self.networkIsSatisfied = networkIsSatisfied
            self.networkTransitionSerial = networkTransitionSerial
            self.physicalReadIsInFlight = physicalReadIsInFlight
            self.now = now
        }
    }

    /// Identity of a logical admission; physical ownership outlives window retirement.
    public struct ReadToken: Equatable, Sendable {
        /// The provider lifecycle that admitted this read.
        public let generation: UInt64
        /// The window that alone may consume this result.
        public let windowSerial: Int
        /// Admission identity within the provider generation, including failed reads.
        public let readIdentity: Int
    }

    /// The next effect; neither kind of waiting performs credential work.
    public enum Action: Equatable, Sendable {
        /// Keep the cheap pre-unlock/active-window timer.
        case wait
        /// Retain eligibility without a timer, awaiting a path callback or owned slot drain.
        case dormant
        /// Read current eligibility and credentials off the DNS queue.
        case checkReadiness(ReadToken)
        /// Retire this recovery without changing protection or configuration.
        case stop
    }

    /// The boot lifecycle this policy alone may restart.
    public let generation: UInt64
    /// Retained for a post-unlock breadcrumb when the protected boot log was unwritable.
    public let refusal: TunnelDataPathLatch.Refusal
    /// Whether no further probe or restart may be admitted.
    public private(set) var isFinished = false
    /// Number of admitted reads, including failures and reads that never return.
    public private(set) var readinessChecks = 0
    /// Lifetime count; network flaps and duplicate callbacks never refund a window.
    public private(set) var onlineWindows = 0
    /// Whether the caller needs a timer; offline and expired waiting hold only bounded state.
    public private(set) var pollingIsNeeded = true
    private var hasObservedUnlock = false
    private var windowStartedAt: TimeInterval?
    private var windowTransitionSerial: UInt64 = 0
    private var nextReadinessAt: TimeInterval = 0
    private var inFlightToken: ReadToken?
    private var lastObservedAt: TimeInterval?

    /// Arms only storage-related refusals observed on a protected boot start.
    /// Persistent surrender, device exclusion, disabled chaining and normal starts are excluded.
    public init?(generation: UInt64, startedWithProtectedDataUnavailable: Bool,
                 refusal: TunnelDataPathLatch.Refusal?) {
        guard startedWithProtectedDataUnavailable, let refusal else { return nil }
        switch refusal {
        case .configurationUnreadable, .deviceStateUnavailable, .upstreamUnavailable:
            self.generation = generation
            self.refusal = refusal
        default:
            return nil
        }
    }

    /// Admits bounded work. Offline unlock spends neither an online window nor a read.
    public mutating func nextAction(_ context: Context) -> Action {
        guard validateOwnershipAndTime(context) else { return stop() }
        retireExpiredWindow(at: context.now)
        guard !isFinished else { return .stop }
        if windowStartedAt != nil {
            windowTransitionSerial = max(windowTransitionSerial, context.networkTransitionSerial)
        }
        guard context.protectedDataIsReadable else {
            pollingIsNeeded = !hasObservedUnlock || (windowStartedAt != nil && context.networkIsSatisfied)
            return pollingIsNeeded ? .wait : .dormant
        }
        hasObservedUnlock = true
        guard intentAllowsRecovery(context) else { return stop() }
        if inFlightToken == nil, readinessChecks >= Self.maxReadinessChecks { return stop() }
        guard context.networkIsSatisfied else {
            pollingIsNeeded = false
            return .dormant
        }
        if windowStartedAt == nil {
            guard onlineWindows < Self.maxOnlineWindows,
                  readinessChecks < Self.maxReadinessChecks else { return stop() }
            // The initial delivered path needs no edge after unlock. Later windows need an
            // edge not consumed while their predecessor was live, never a duplicate/interface roam.
            guard onlineWindows == 0 || context.networkTransitionSerial > windowTransitionSerial else {
                pollingIsNeeded = false
                return .dormant
            }
            onlineWindows += 1
            windowStartedAt = context.now
            windowTransitionSerial = context.networkTransitionSerial
            nextReadinessAt = max(nextReadinessAt, context.now)
        }
        pollingIsNeeded = true
        guard inFlightToken == nil, !context.physicalReadIsInFlight,
              context.now >= nextReadinessAt else { return .wait }
        readinessChecks += 1
        let token = ReadToken(generation: generation, windowSerial: onlineWindows,
                              readIdentity: readinessChecks)
        inFlightToken = token
        nextReadinessAt = context.now + Self.pollInterval
        return .checkReadiness(token)
    }

    /// Revalidates the existing non-secret disclosure marker, without reading eligibility keys.
    /// A fresh/cleared marker may coexist with a boot refusal; explicit retry or another reason
    /// belongs to another recovery owner and cannot authorize this protected-boot restart.
    public func matchesDurableRefusal(_ state: ChainedStartupFailureMarker.State,
                                      expectedMarkerGeneration: UInt64) -> Bool {
        state.generation == expectedMarkerGeneration && !state.explicitRetryRequested
            && (state.reason == nil || state.reason == refusal.logValue)
    }

    /// Applies lifecycle/configuration invalidation without opening a window or admitting a read.
    /// Existing app/configuration owners can retire dormant work without adding polling.
    public mutating func revalidate(_ context: Context) -> Bool {
        guard validateOwnershipAndTime(context) else { _ = stop(); return false }
        retireExpiredWindow(at: context.now)
        if context.protectedDataIsReadable && !intentAllowsRecovery(context) { _ = stop() }
        return !isFinished
    }

    /// Only the admitted, current, unexpired window may consume a result or grant restart.
    /// Slot drain is separate: an expired/old result cannot complete a newer logical read.
    public mutating func completeReadinessCheck(
        _ context: Context, token: ReadToken, upstreamIsReady: Bool
    ) -> Bool {
        guard token == inFlightToken else { return false }
        guard validateOwnershipAndTime(context) else { _ = stop(); return false }
        retireExpiredWindow(at: context.now)
        guard token == inFlightToken else { return false }
        inFlightToken = nil
        guard context.protectedDataIsReadable else {
            if readinessChecks >= Self.maxReadinessChecks { _ = stop() }
            return false
        }
        guard intentAllowsRecovery(context) else { _ = stop(); return false }
        if upstreamIsReady, context.networkIsSatisfied {
            _ = stop()
            return true
        }
        if readinessChecks >= Self.maxReadinessChecks { _ = stop() }
        return false
    }

    private mutating func validateOwnershipAndTime(_ context: Context) -> Bool {
        guard !isFinished, context.now.isFinite,
              lastObservedAt.map({ context.now >= $0 }) ?? true,
              context.lifecycleIsActive, context.generation == generation,
              context.refusal == refusal else { return false }
        lastObservedAt = context.now
        return true
    }

    private func intentAllowsRecovery(_ context: Context) -> Bool {
        context.protectionIsWanted && context.chainingIsEnabled && context.onDemandIsEnabled
    }

    private mutating func retireExpiredWindow(at now: TimeInterval) {
        guard let startedAt = windowStartedAt, now - startedAt >= Self.recoveryWindow else { return }
        windowStartedAt = nil
        inFlightToken = nil
        pollingIsNeeded = false
        if onlineWindows >= Self.maxOnlineWindows || readinessChecks >= Self.maxReadinessChecks {
            _ = stop()
        }
    }

    private mutating func stop() -> Action {
        isFinished = true
        pollingIsNeeded = false
        windowStartedAt = nil
        inFlightToken = nil
        return .stop
    }
}
