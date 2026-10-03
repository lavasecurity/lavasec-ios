import Foundation

/// Derives a non-colliding filter name from a base the app supplies.
///
/// This is the one implementation behind every *derived* filter name — both the
/// duplicate/created-filter path (`AppViewModel.uniqueFilterName`) and shared
/// filters arriving from an import. Keeping them unified is deliberate: a user
/// who duplicates a filter and a user who imports one should not meet two
/// different numbering conventions.
///
/// For shared filters this is also a security-relevant boundary. The share
/// payload deliberately excludes the sender's library name — rendering it would
/// let an untrusted party choose text that appears in the recipient's filter
/// list — so an imported filter is always named locally. That makes collision
/// handling load-bearing rather than cosmetic: importing the same card twice
/// must produce two filters, and must never silently overwrite an existing one.
///
/// Collision matching intentionally mirrors `AppViewModel.isFilterNameAvailable`
/// (trimmed, `localizedCaseInsensitiveCompare`). If the two ever diverge, this
/// policy could hand back a name the library then rejects as a duplicate.
public enum SharedFilterNamePolicy {
    /// The first free name in the sequence `base`, `base 2`, `base 3`, …
    ///
    /// Fills the lowest free slot rather than appending past the highest, so
    /// deleting a filter frees its number for reuse. The sequence starts at 2
    /// because the unnumbered base *is* the first one.
    ///
    /// - Parameters:
    ///   - base: An already-localized display name. Trimmed before use; the
    ///     caller owns any empty-base fallback, since this package does not
    ///     localize.
    ///   - existingNames: Every name currently taken. For a *replacement*, pass
    ///     every name except the target's own, so the target can keep the slot it
    ///     already occupies instead of being bumped by its own presence.
    ///   - numberedFromOne: Creation can request `base 1`, `base 2`, … while
    ///     imports and existing derived names retain their unnumbered first slot.
    /// - Returns: A name no entry in `existingNames` collides with.
    public static func nextAvailableName(base: String, existingNames: [String], numberedFromOne: Bool = false) -> String {
        let root = base.trimmingCharacters(in: .whitespacesAndNewlines)
        let taken = existingNames.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        func isAvailable(_ candidate: String) -> Bool {
            !taken.contains { $0.localizedCaseInsensitiveCompare(candidate) == .orderedSame }
        }

        if !numberedFromOne && isAvailable(root) {
            return root
        }

        // Bounded by the number of existing names: with n names taken, at most n
        // suffixes can be occupied, so a free slot always appears by n + 2.
        var suffix = numberedFromOne ? 1 : 2
        while !isAvailable("\(root) \(suffix)") {
            suffix += 1
        }
        return "\(root) \(suffix)"
    }
}
