import Foundation

/// Decides, once per tunnel session, which data path that session will run.
///
/// Plan: lavasec-infra `plans/2026-07-22-vpn-upstream-chaining-implementation-plan.md` (D1).
///
/// ## Why this is a type and not an `if` in the provider
///
/// The decision has five independent terms and a defined precedence, and getting the
/// precedence wrong produces a *plausible-looking* wrong answer rather than a crash: a
/// build with no data path that reports "not enough memory" sends the user to replace a
/// phone that was never the problem. Keeping it here makes every term and every ordering
/// executable-testable without a tunnel process, which is what
/// `TunnelDataPathLatchTests` exhausts. The provider keeps only the wiring — resolve at
/// start, store, read.
///
/// ## Refusal is reported, not swallowed
///
/// Every `dnsOnly` resolution carries the reason it is not chained. The app's reconcile
/// (D1) distinguishes a *transient* cause (the WireGuard secret is not readable before
/// first unlock) from a *persistent* one (a provider build with no chained data path, a
/// secret that did not migrate on restore) — one restarts when the cause clears, the other
/// must not enter a restart loop. That distinction is only possible if the refusal survives
/// the decision.
public enum TunnelDataPathLatch {
    /// Why the latch declined to run the chained data path.
    ///
    /// These are log/health identifiers, never user copy — the Phase-4/5 UI maps them to
    /// localized strings.
    public enum Refusal: Equatable, Sendable {
        /// The shared configuration could not be read, so what the user wanted is unknown.
        ///
        /// Outranks every other cause, including `chainingDisabled`. A Connect-On-Demand
        /// boot before first unlock reads the config as existing-but-unreadable
        /// (`INV-PERSIST-1`) and the tunnel proceeds on an empty placeholder — whose
        /// chaining flag is `false` because the placeholder is empty, not because the user
        /// turned it off. Reporting `chainingDisabled` there would state a preference the
        /// tunnel never read, and it is the one refusal the app deliberately does not
        /// reconcile, so a device that genuinely wanted chaining would sit in DNS-only until
        /// something unrelated restarted the tunnel.
        case configurationUnreadable
        /// The user has not turned chaining on. Not a fault, and never a reconcile trigger:
        /// the app only reconciles "flag on, latched DNS-only".
        case chainingDisabled
        /// This build has no chained data path to run. Persistent, and not something the
        /// user can act on — an older provider alongside a newer app.
        case unsupportedByBuild
        /// The device-local eligibility state (the experimental override and startup-loop
        /// breaker) could not be read, so what THIS DEVICE knows about itself is unknown.
        ///
        /// Outranks `deviceIneligible` for the same reason `configurationUnreadable`
        /// outranks `chainingDisabled`: an ineligibility computed from guessed terms is a
        /// statement about the device the tunnel never actually read. The concrete harm is
        /// the override's: a sub-floor device the user opted in, read as "override off" on
        /// a pre-first-unlock boot, would be refused `.insufficientMemory` — the one cause
        /// the app's reconcile treats as durable enough to CLEAR the stored preference.
        /// Transient: the state is Keychain `AfterFirstUnlockThisDeviceOnly`, so the next
        /// post-unlock start reads it. An observed locked startup schedules that start through
        /// `ChainedBootRecoveryPolicy` without waiting for a manual toggle (INV-CHAIN-BOOT-1).
        case deviceStateUnavailable
        /// The account or the device cannot run chained mode.
        case deviceIneligible(ChainedAvailability.Ineligibility)
        /// Chained mode surrendered — the outage budget expired — and no explicit Guard start
        /// has cleared it (C4).
        ///
        /// Ranked BELOW `deviceIneligible` and ABOVE `upstreamUnavailable`, and both edges
        /// are decisions. An ineligible device's surrender is not the actionable fact: an
        /// unentitled or sub-floor device cannot chain, while a startup-loop trip is the more
        /// durable cause. An explicit Guard start clears both recoverable latches. Against the upstream
        /// term, the surrender is the durable cause and the upstream's readability is the
        /// transient one: a surrendered device whose secret happens to be unreadable right
        /// now must still name the surrender.
        ///
        /// Persists until an explicit Guard start clears the stored suppression. It never clears
        /// the saved chaining preference, and the provider will fail closed rather than start a
        /// DNS-only session that contradicts that preference.
        case chainedSurrendered
        /// Chaining is on and the device qualifies, but the upstream cannot be used at this
        /// moment. Three producer classes: the configuration does not parse; the
        /// provider's chained-runtime construction downgraded this lifecycle (an endpoint
        /// that is not an IP literal until S1 lands — persistent PER CONFIGURATION, not
        /// transient — an AllowedIPs parse drift, or a first-session build failure; see
        /// `PacketTunnelProvider.downgradeChainedConstruction`); or the WireGuard secret
        /// is not readable yet (a boot before first unlock; the secret is Keychain
        /// `AfterFirstUnlockThisDeviceOnly`). Transient in the pre-unlock case, persistent
        /// when the secret did not migrate to a restored device.
        case upstreamUnavailable

        /// Whether a later start can clear this refusal without any user action: the device was
        /// locked (configuration or device-local state unreadable). A retryable refusal must
        /// never become a terminal marker or an automatic OFF — the tunnel starts the latched
        /// DNS-only path and keeps filtering while the next attempt waits (2026-09-17 fail-open
        /// incident: a locked-device read was classified terminal, the app disarmed
        /// Connect-On-Demand and persisted OFF, and the device sat unfiltered).
        ///
        /// `upstreamUnavailable` is deliberately DURABLE: the transient pre-unlock secret read
        /// shares the case with the persistent construction downgrades
        /// (`endpoint-not-a-literal`, `allowed-ips-unparsable`, `first-session-build-failed`),
        /// and none of those is cleared by a retry. Fail-closed startup runs DNS-only under
        /// either, so the classification only decides how the surface presents it.
        /// Boot recovery uses separate evidence of a locked start and fresh readiness; it
        /// does not turn every construction/credential failure into a retryable refusal.
        /// pinned: ChainedStartupContractTests.testARequestedChainNeverStartsUnfiltered
        public var isRetryable: Bool {
            switch self {
            case .configurationUnreadable, .deviceStateUnavailable:
                return true
            case .chainingDisabled, .unsupportedByBuild, .deviceIneligible, .chainedSurrendered,
                 .upstreamUnavailable:
                return false
            }
        }

        /// Stable identifier for device logs and health state.
        public var logValue: String {
            switch self {
            case .configurationUnreadable:
                return "configuration-unreadable"
            case .chainingDisabled:
                return "chaining-disabled"
            case .unsupportedByBuild:
                return "unsupported-by-build"
            case .deviceStateUnavailable:
                return "device-state-unavailable"
            case .deviceIneligible(let reason):
                return "device-\(reason.rawValue)"
            case .chainedSurrendered:
                return "chained-surrendered"
            case .upstreamUnavailable:
                return "upstream-unavailable"
            }
        }
    }

    /// The latched mode plus the reason it is not chained.
    ///
    /// `refusal` is non-`nil` for exactly the `dnsOnly` resolutions — a chained resolution
    /// has nothing to explain. `TunnelDataPathLatchTests` asserts both halves of that
    /// biconditional over every input combination, so a future term cannot be added in a
    /// way that resolves `dnsOnly` without saying why.
    public struct Resolution: Equatable, Sendable {
        /// The data path this session runs.
        public let mode: TunnelDataPathMode
        /// Why `mode` is not `chainedUpstream`, or `nil` when it is.
        public let refusal: Refusal?

        public init(mode: TunnelDataPathMode, refusal: Refusal?) {
            self.mode = mode
            self.refusal = refusal
        }
    }

    /// Resolves the data path for one tunnel session.
    ///
    /// The terms are evaluated most-durable-cause-first, so the reported refusal is the one
    /// worth acting on. In particular `buildSupportsChainedDataPath` is checked *before*
    /// device eligibility: on a build with no data path every device would otherwise be
    /// reported as ineligible for whatever reason happened to come first, which is a false
    /// diagnosis of a working device.
    ///
    /// Refusing is always safe and claiming is not, so every term defaults toward `dnsOnly`.
    /// A tunnel that claims `0.0.0.0/0` with no upstream it can reach is a blackhole, not a
    /// degraded mode — DNS-only filtering still protects the user, so there is no case in
    /// which guessing "chained" beats refusing.
    ///
    /// - Parameters:
    ///   - configurationIsUnreadable: Whether the shared configuration existed but could not
    ///     be decrypted (`INV-PERSIST-1`). When true the other configuration-derived
    ///     arguments are placeholders and are ignored.
    ///   - chainedUpstreamEnabled: The user's flag, from the shared configuration.
    ///   - buildSupportsChainedDataPath: Whether this build actually links and can drive the
    ///     WireGuard engine. Ships `true` since the S8.8b flip slice wired the data path;
    ///     `false` now describes only an older provider running beside a newer app.
    ///   - hasLavaSecurityPlus: Entitlement, from the shared configuration.
    ///   - physicalMemoryBytes: `ProcessInfo.processInfo.physicalMemory`.
    ///   - deviceLocalStateIsUnavailable: Whether the device-local eligibility store could
    ///     not be read (`ChainedDeviceEligibilityStore.ReadOutcome.unavailable`). When true
    ///     the two device-local arguments below are placeholders and are ignored — the same
    ///     contract `configurationIsUnreadable` has with the configuration-derived ones.
    ///   - experimentalOverrideEnabled: The device-local opt-in for sub-floor hardware.
    ///   - hasStartupCrashLoopTripped: Set after repeated same-build exits before chained
    ///     forwarding was proven.
    ///   - isSurrenderSuppressed: Whether a previous session's surrender is still standing
    ///     (C4) — persisted device-locally, cleared by an explicit Guard start. When the
    ///     device-local state is unavailable this argument is a placeholder like the two
    ///     above it, shadowed by the `deviceStateUnavailable` guard: an unreadable store
    ///     must not be read as "not suppressed", or a pre-unlock boot re-enters the mode
    ///     the notice said turned itself off.
    ///   - readyUpstream: The validated upstream configuration, when it parses *and* its
    ///     secret is readable right now — `nil` otherwise. Evaluated at latch time, not
    ///     cached from a previous session. The configuration itself rather than a Bool,
    ///     because a chained resolution carries it as the mode's payload (C7): the route
    ///     plan claims the configured `[Interface]` Address, and requiring the value here
    ///     is what makes "latched chained with nothing to claim from" unrepresentable —
    ///     the same required-argument shape the S8 constraints repeat.
    public static func resolve(
        configurationIsUnreadable: Bool,
        chainedUpstreamEnabled: Bool,
        buildSupportsChainedDataPath: Bool,
        hasLavaSecurityPlus: Bool,
        physicalMemoryBytes: UInt64,
        deviceLocalStateIsUnavailable: Bool,
        experimentalOverrideEnabled: Bool,
        hasStartupCrashLoopTripped: Bool,
        isSurrenderSuppressed: Bool,
        readyUpstream: ChainedUpstreamConfiguration?
    ) -> Resolution {
        guard !configurationIsUnreadable else {
            return Resolution(mode: .dnsOnly, refusal: .configurationUnreadable)
        }
        guard chainedUpstreamEnabled else {
            return Resolution(mode: .dnsOnly, refusal: .chainingDisabled)
        }
        guard buildSupportsChainedDataPath else {
            return Resolution(mode: .dnsOnly, refusal: .unsupportedByBuild)
        }
        guard !deviceLocalStateIsUnavailable else {
            return Resolution(mode: .dnsOnly, refusal: .deviceStateUnavailable)
        }
        if let reason = ChainedAvailability.ineligibilityReason(
            hasLavaSecurityPlus: hasLavaSecurityPlus,
            physicalMemoryBytes: physicalMemoryBytes,
            experimentalOverrideEnabled: experimentalOverrideEnabled,
            hasStartupCrashLoopTripped: hasStartupCrashLoopTripped
        ) {
            return Resolution(mode: .dnsOnly, refusal: .deviceIneligible(reason))
        }
        guard !isSurrenderSuppressed else {
            return Resolution(mode: .dnsOnly, refusal: .chainedSurrendered)
        }
        guard let upstream = readyUpstream else {
            return Resolution(mode: .dnsOnly, refusal: .upstreamUnavailable)
        }
        return Resolution(mode: .chainedUpstream(upstream), refusal: nil)
    }
}
