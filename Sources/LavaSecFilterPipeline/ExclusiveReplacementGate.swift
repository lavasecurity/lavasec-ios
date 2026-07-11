import Foundation
import LavaSecKit

/// A monotonic epoch that serializes wholesale replacements of the live configuration +
/// filter library against one another.
///
/// Several `@MainActor async` operations replace the active configuration and filter
/// library wholesale — a filter **switch**, an encrypted-backup **restore**, a shared-config
/// **import**, and a My-filter **draft apply**. Each suspends at an `await` (snapshot
/// preparation, envelope fetch, passkey unlock, and the artifact-publish actor hop inside the
/// shared persist) during which another such operation can run to completion on the main
/// actor. Without a shared serialization token the operation that *resumes last* wins and
/// silently reverts whatever committed while it was suspended — e.g. a resuming switch
/// clobbering a completed restore, or running its derived-cache side-effect tail over it.
///
/// The gate is the single source of truth for "who currently owns the configuration":
/// every replacer calls ``begin()`` before its first `await`, capturing a token, and
/// re-checks ``isCurrent(_:)`` before it commits, before its post-persist side-effect tail,
/// and before any rollback. A newer ``begin()`` supersedes every outstanding token, so a
/// superseded operation bails instead of committing, running side effects, or rolling back
/// over the newer owner.
///
/// This is a plain value type mutated only on the main actor (all replacers are
/// `@MainActor`), so the read-modify-write in ``begin()`` is not racy. It is factored out
/// of `AppViewModel` so the supersession invariant can be exercised by real behavioural
/// tests rather than only asserted by source introspection.
public struct ExclusiveReplacementGate: Equatable, Sendable {
    /// The current epoch. Starts at 0 (no replacement has run); every ``begin(ownsPreparationCover:)``
    /// advances it. Exposed read-only for diagnostics/tests.
    public private(set) var epoch: Int

    /// Whether the CURRENT owner drives the shared filter-preparation cover (a switch or a
    /// draft apply do; a backup restore or shared-config import do not). A superseded
    /// cover-driver reads this to decide whether to dismiss the cover it put up: if the new
    /// owner is also a cover-driver it will manage the cover, but if the new owner is a
    /// non-cover-driver (restore/import) nobody else will dismiss it, so the superseded op must.
    public private(set) var currentOwnerOwnsPreparationCover: Bool

    /// Creates a gate with an initial epoch and preparation-cover ownership state.
    public init(epoch: Int = 0, currentOwnerOwnsPreparationCover: Bool = false) {
        self.epoch = epoch
        self.currentOwnerOwnsPreparationCover = currentOwnerOwnsPreparationCover
    }

    /// Claim ownership of the next replacement. Advances the epoch (monotonic, wraps via
    /// `&+` only after `Int.max` replacements — unreachable) and returns the claiming token.
    /// The caller holds this token across its `await`s and passes it to ``isCurrent(_:)``.
    /// `ownsPreparationCover` records whether this owner drives the preparation cover.
    public mutating func begin(ownsPreparationCover: Bool = false) -> Int {
        epoch = epoch &+ 1
        currentOwnerOwnsPreparationCover = ownsPreparationCover
        return epoch
    }

    /// Whether `token` still owns the configuration — i.e. no newer ``begin()`` has run
    /// since it was claimed. A superseded caller must NOT commit or roll back: doing so
    /// would clobber the newer owner's already-committed state.
    public func isCurrent(_ token: Int) -> Bool {
        token == epoch
    }
}
