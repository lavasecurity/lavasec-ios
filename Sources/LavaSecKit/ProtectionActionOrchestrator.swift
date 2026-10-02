import Foundation

/// Mutually exclusive protection operations coordinated by the app's main-actor action gate.
public enum ProtectionActionKind: String, CaseIterable, Equatable, Sendable {
    /// Enables protection.
    case turnOn
    /// Disables protection.
    case turnOff
    /// Chooses enable or disable from the current lifecycle state.
    case toggle
    /// Stops and restarts the active protection tunnel.
    case reconnect
    /// Rebuilds and applies the active filter lists.
    case refreshLists
    /// Temporarily pauses filtering.
    case pause
    /// Resumes filtering after a pause.
    case resume
    /// Installs the production VPN profile during onboarding.
    case installProfile
    /// Installs, removes, or resets the profile from internal admin-QA controls.
    case adminQAProfile
}

/// A restore request captured before configuration work first suspends.
///
/// `wasEnabled` preserves the caller's reason for considering a restore. The intended direction and
/// revision preserve explicit user intent independently of status-derived configuration fields, which
/// a refresh is allowed to rewrite while the request is in flight.
public struct ProtectionRestoreRequest: Equatable, Sendable {
    /// Whether sticky explicit intent made restoration eligible when the request was captured.
    public let wasEnabled: Bool
    /// Explicit on/off direction captured independently of observed tunnel status.
    public let intendedEnabled: Bool
    /// Intent generation used to reject work captured before a later user action.
    public let intentRevision: UInt64
    /// Durable generation of the latest accepted direct App Intent restart at capture time.
    public let externalRestartGeneration: String?

    /// Creates an immutable restore request captured before asynchronous refresh work begins.
    public init(
        wasEnabled: Bool,
        intendedEnabled: Bool,
        intentRevision: UInt64,
        externalRestartGeneration: String? = nil
    ) {
        self.wasEnabled = wasEnabled
        self.intendedEnabled = intendedEnabled
        self.intentRevision = intentRevision
        self.externalRestartGeneration = externalRestartGeneration
    }
}

/// Main-actor-owned explicit protection intent used to validate automatic restore requests.
///
/// The type itself is a value so its revision behavior is deterministic and testable; the app owns a
/// single instance and never updates it from status observation. Every accepted user lifecycle action
/// advances the revision, including same-direction reconnects, so work captured before that action
/// cannot restore over it. Protected-data recovery also advances the revision when replacing a launch
/// placeholder with the configuration that was actually loaded after unlock.
public struct ProtectionRestoreIntentState: Equatable, Sendable {
    /// Latest explicit loaded or user-selected protection direction.
    public private(set) var isEnabled: Bool
    /// Monotonic generation advanced by every authoritative intent replacement.
    public private(set) var revision: UInt64

    /// Creates sticky intent state from the best authoritative configuration currently available.
    public init(isEnabled: Bool, revision: UInt64 = 0) {
        self.isEnabled = isEnabled
        self.revision = revision
    }

    /// Records a user lifecycle choice and invalidates every request captured before it.
    public mutating func recordUserIntent(isEnabled: Bool) {
        self.isEnabled = isEnabled
        revision &+= 1
    }

    /// Replaces a launch placeholder with configuration loaded after protected data becomes available.
    public mutating func recoverFromLoadedConfiguration(isEnabled: Bool) {
        self.isEnabled = isEnabled
        revision &+= 1
    }

    /// Captures the current sticky intent and optional external-Restart generation for restoration.
    public func makeRestoreRequest(
        externalRestartGeneration: String? = nil
    ) -> ProtectionRestoreRequest {
        ProtectionRestoreRequest(
            // Eligibility follows the sticky loaded/user intent. A status refresh may have already
            // rewritten the compatibility configuration hint to false before a launch caller gets
            // to capture its request; that observation must not erase explicit intent.
            wasEnabled: isEnabled,
            intendedEnabled: isEnabled,
            intentRevision: revision,
            externalRestartGeneration: externalRestartGeneration
        )
    }

    /// Compatibility overload for callers compiled against the earlier status-derived capture API.
    /// The observed value is intentionally ignored: explicit loaded/user intent is authoritative.
    public func makeRestoreRequest(
        wasEnabled _: Bool,
        externalRestartGeneration: String? = nil
    ) -> ProtectionRestoreRequest {
        makeRestoreRequest(externalRestartGeneration: externalRestartGeneration)
    }

    /// Returns whether a captured request still matches the latest explicit intent generation.
    public func allows(_ request: ProtectionRestoreRequest) -> Bool {
        request.wasEnabled
            && request.intendedEnabled
            && isEnabled
            && request.intentRevision == revision
    }

    /// Admits an explicit reconnect captured before authorization without overriding newer intent.
    ///
    /// An unchanged OFF capture may explicitly request a fresh start. An ON capture must retain
    /// its current ON direction, and every later user choice supersedes either capture.
    public func allowsExplicitReconnect(_ request: ProtectionRestoreRequest) -> Bool {
        request.intentRevision == revision && (!request.wasEnabled || allows(request))
    }
}

/// Single-flight gate preventing in-app protection actions from interleaving.
///
/// Entry points claim a kind synchronously before their first suspension and release only their own
/// claim. UI in-flight state is derived through the callback rather than written independently.
@MainActor
public final class ProtectionActionOrchestrator {
    /// The currently owned action, or `nil` while the gate is idle.
    public private(set) var inFlightAction: ProtectionActionKind?

    private let onInFlightChange: @MainActor (ProtectionActionKind?) -> Void

    /// Creates an idle gate and reports every ownership transition through `onInFlightChange`.
    public init(onInFlightChange: @escaping @MainActor (ProtectionActionKind?) -> Void = { _ in }) {
        self.onInFlightChange = onInFlightChange
    }

    /// Whether any protection action currently owns the gate.
    public var isActionInFlight: Bool {
        inFlightAction != nil
    }

    /// Tries once to claim an idle gate for `kind`; returns `false` without waiting when occupied.
    @discardableResult
    public func claim(_ kind: ProtectionActionKind) -> Bool {
        guard inFlightAction == nil else {
            return false
        }

        inFlightAction = kind
        onInFlightChange(kind)
        return true
    }

    /// Releases only a matching claim, so stale cleanup cannot end a newer action.
    public func release(_ kind: ProtectionActionKind) {
        guard inFlightAction == kind else {
            return
        }

        inFlightAction = nil
        onInFlightChange(nil)
    }

    /// Runs an async operation under a try-once claim and returns `false` when it was skipped.
    @discardableResult
    public func run(_ kind: ProtectionActionKind, operation: () async -> Void) async -> Bool {
        guard claim(kind) else {
            return false
        }

        defer {
            release(kind)
        }
        await operation()
        return true
    }

    /// Refreshes protection state, then atomically revalidates live restore intent and claims the
    /// turn-on action before running an automatic restore.
    ///
    /// The refresh is intentionally outside the claim because it can be slow and must not block a
    /// user action. Once it returns, `shouldRestore` and `claim(.turnOn)` run synchronously on the
    /// main actor with no suspension between them. A turn-off that completed during the refresh
    /// therefore wins, and an action that claimed the orchestrator during the refresh is never
    /// interleaved with the restore.
    ///
    /// - Parameters:
    ///   - refresh: Reloads the live protection state used by `shouldRestore`.
    ///   - shouldRestore: Revalidates the current explicit intent and connection state.
    ///   - claimExternalExclusion: Atomically claims any cross-process lifecycle exclusion after
    ///     the local action claim. It must not suspend.
    ///   - validateExternalExclusion: Renews/revalidates that exclusion. The operation receives the
    ///     same closure so it can abort after any long suspension before mutating lifecycle state.
    ///   - releaseExternalExclusion: Asynchronously releases the external claim after the operation
    ///     finishes. The local action claim remains held until this cleanup settles.
    ///   - operation: Performs the automatic turn-on after the claim succeeds and returns whether it
    ///     completed without losing ownership.
    /// - Returns: `true` when the restore operation completed while owned; otherwise `false`.
    @discardableResult
    public func runAutomaticRestoreAfterRefresh(
        refresh: () async -> Void,
        shouldRestore: () -> Bool,
        claimExternalExclusion: () -> Bool = { true },
        validateExternalExclusion: @escaping @MainActor () -> Bool = { true },
        releaseExternalExclusion: () async -> Void = {},
        operation: (_ validateExternalExclusion: @escaping @MainActor () -> Bool) async -> Bool
    ) async -> Bool {
        await refresh()
        guard shouldRestore(), claim(.turnOn) else {
            return false
        }

        guard claimExternalExclusion() else {
            release(.turnOn)
            return false
        }

        let completedWhileOwned: Bool
        if validateExternalExclusion() {
            completedWhileOwned = await operation(validateExternalExclusion)
        } else {
            completedWhileOwned = false
        }
        await releaseExternalExclusion()
        release(.turnOn)
        return completedWhileOwned
    }
}
