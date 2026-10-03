/// Keeps protected preference defaults provisional until the first readable load.
/// Availability is supplied by the app; this policy never probes storage or UIKit.
public struct ProtectedPreferenceRecovery: Sendable {
    /// Whether this process has loaded preferences from available storage.
    public private(set) var hasLoaded = false

    /// Starts a process with no confirmed preference snapshot.
    public init() {}

    /// Defers loading until both protected data and the real shared configuration are available.
    /// Once loaded, foreground notifications must not overwrite subsequent in-memory edits.
    public func shouldLoad(protectedDataIsAvailable: Bool, sharedStateIsAvailable: Bool) -> Bool {
        !hasLoaded && protectedDataIsAvailable && sharedStateIsAvailable
    }

    /// Records completion of the synchronous preference load.
    public mutating func didLoad() {
        hasLoaded = true
    }

    /// Refuses writes and preference-dependent effects from a provisional snapshot.
    /// Class-C preferences remain accessible after first unlock, including later screen locks.
    public func canUsePreferences(sharedStateIsAvailable: Bool) -> Bool {
        hasLoaded && sharedStateIsAvailable
    }
}
