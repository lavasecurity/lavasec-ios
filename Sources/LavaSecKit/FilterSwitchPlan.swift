import Foundation

/// The PURE state transition for switching the active filter, shared by the foreground switch
/// (`AppViewModel.switchToFilter`, operating on in-memory state) and the headless warm switch service
/// (operating on file-loaded state). Keeping the transition in one place is the single source of truth
/// for "what a switch changes" — the four scoped fields mirrored from the target filter into the live
/// configuration, plus the library's active selection — so the two execution contexts can never drift
/// on the semantics of a switch.
///
/// Deliberately does NOT bump `configurationGeneration` or touch any files: the generation bump belongs
/// to the ordered WRITE step (it must read the on-disk generation at write time), and this stays a pure,
/// deterministic, side-effect-free value transformation. It also does NOT enforce gates (Plus,
/// auth-to-edit, frozen) — those are the caller's security boundary — only that the target exists.
public enum FilterSwitchPlan {
    /// Result of planning a switch: the new configuration (target's four fields mirrored in) and the new
    /// library (active selection moved to the target). `generationBump` is intentionally absent — apply
    /// it at write time against the on-disk generation.
    public struct Outcome: Equatable, Sendable {
        public let configuration: AppConfiguration
        public let library: FilterLibrary

        public init(configuration: AppConfiguration, library: FilterLibrary) {
            self.configuration = configuration
            self.library = library
        }
    }

    /// Plan a switch of the active filter to `targetID`. Returns `nil` when the target does not exist in
    /// the library (a deleted/unknown id) or is already active (a no-op switch). Otherwise returns the
    /// mirrored configuration + the library with `activeFilterID == targetID`.
    public static func make(
        toFilterID targetID: String,
        configuration: AppConfiguration,
        library: FilterLibrary
    ) -> Outcome? {
        guard targetID != library.activeFilterID,
              let target = library.filter(id: targetID) else {
            return nil
        }

        var newConfiguration = configuration
        newConfiguration.enabledBlocklistIDs = target.enabledBlocklistIDs
        newConfiguration.customBlocklists = target.customBlocklists
        newConfiguration.blockedDomains = target.blockedDomains
        newConfiguration.allowedDomains = target.allowedDomains

        var newLibrary = library
        newLibrary.setActiveFilter(id: targetID)
        // setActiveFilter is a no-op if the id isn't in the library; we already verified it exists, so
        // this always lands. Guard defensively so a future library invariant change can't silently
        // produce a configuration/library mismatch.
        guard newLibrary.activeFilterID == targetID else {
            return nil
        }

        return Outcome(configuration: newConfiguration, library: newLibrary)
    }
}
