import Foundation

/// Durable, pre-unlock-readable marker for the launch-reseed automatic-backup suppression
/// (INV-PERSIST-2). Its EXISTENCE means "the on-disk filter library is a recovery reseed a
/// prior launch persisted over an absent/corrupt store — suppress automatic backup until a
/// user-authoritative recovery (restore / restore-to-default / onboarding seed) supersedes it,
/// so an automatic upload cannot clobber the user's last good server envelope."
///
/// Stored as a Class-None FILE, NOT in `UserDefaults.standard` (Codex P1 + Kilo/OCR follow-up
/// on the 1.2.4 sync). INV-PERSIST-2 made `filter-library.json` Class-None, so a
/// reboot-before-first-unlock launch can ACCEPT the library and must be able to read AND durably
/// write this marker in lockstep with it. A Class-C `UserDefaults` marker could do neither: its
/// read returned a spurious `false` while the standard defaults were locked, and its write could
/// not land durably pre-unlock — and `UserDefaults.synchronize()` is a no-op on modern iOS, so
/// the "crash barrier" the old marker's ordering relied on never existed. A Class-None file's
/// existence is readable via metadata while locked, and its atomic write lands durably
/// pre-unlock, exactly matching the library it guards. Because the marker carries app-state (a
/// boolean, by existence), never browsing history, Class-None is the same deliberate trade as
/// the rest of the control plane (`docs/invariants.md` INV-PERSIST-2).
/// - pinned: ReseedSuppressionMarkerStoreTests.testMarkIsReadableAndClearable
public enum ReseedSuppressionMarkerStore {
    /// Marker filename under the shared App Group container. Named to sort near the control-plane
    /// pair it guards; content is deliberately empty — only existence matters.
    public static let markerFilename = "reseed-suppression.marker"

    /// The marker file URL under `containerURL`.
    public static func markerURL(containerURL: URL) -> URL {
        containerURL.appendingPathComponent(markerFilename)
    }

    /// Whether the suppression marker is present. A metadata-only existence probe, so it is
    /// readable BEFORE first unlock (unlike a Class-C `UserDefaults` read).
    public static func isMarked(containerURL: URL, fileManager: FileManager = .default) -> Bool {
        fileManager.fileExists(atPath: markerURL(containerURL: containerURL).path)
    }

    /// Stamp the durable marker as a Class-None atomic write, so a hard kill between this stamp
    /// and the reseed's library-first persist can never leave a durable seeded library WITHOUT
    /// its marker (the pre-unlock clobber window the old Class-C stamp could not close). Idempotent
    /// — a present marker is left as-is. Returns whether the marker is now on disk.
    /// - pinned: ReseedSuppressionMarkerStoreTests.testMarkIsDurableAndIdempotent
    @discardableResult
    public static func mark(containerURL: URL, fileManager: FileManager = .default) -> Bool {
        let url = markerURL(containerURL: containerURL)
        if fileManager.fileExists(atPath: url.path) { return true }
        do {
            // Empty content; Class-None + atomic (INV-PERSIST-2) so the write is durable and the
            // marker is readable before first unlock, matching the Class-None library it guards.
            try Data().write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            return true
        } catch {
            return false
        }
    }

    /// Drop the marker when the library becomes user-authoritative again. Idempotent — a missing
    /// marker is a no-op. Returns whether the marker is now ABSENT: a `false` means the removal
    /// FAILED and the marker is still on disk, so the caller must NOT report the suppression lifted
    /// (the next launch would read `.present` and re-arm it) — the symmetric contract to `mark()`'s
    /// confirmed-on-disk return. Without a return the swallowed remove error left a stuck marker
    /// silently re-suppressing automatic backup while the in-memory flag read cleared (OCR P1 on
    /// the 1.2.5 sync).
    /// - pinned: ReseedSuppressionMarkerStoreTests.testClearReportsWhetherTheMarkerIsGone
    @discardableResult
    public static func clear(containerURL: URL, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.removeItem(at: markerURL(containerURL: containerURL))
            return true
        } catch {
            // Treat ONLY a definite "no such file" as the idempotent success case. Every other
            // failure (permission, a search-permission fault on the parent, metadata I/O, busy) may
            // leave the marker on disk, so report failure and let the caller keep the suppression
            // armed. Do NOT decide "gone" with a `fileExists` probe — under exactly these faults the
            // stat can itself return a spurious `false` for a marker that is still present, which
            // would report a bogus successful clear (Codex P2 on the 1.2.5 sync).
            return Self.isNoSuchFileError(error)
        }
    }

    /// Whether `error` from a `removeItem` definitively means the item did not exist — the only
    /// error class that counts as an idempotent clear success. Matches the Cocoa no-such-file codes
    /// (`NSFileNoSuchFileError` 4 / `NSFileReadNoSuchFileError` 260) and POSIX `ENOENT`, including
    /// an `ENOENT` wrapped as the Cocoa error's underlying cause.
    private static func isNoSuchFileError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain, nsError.code == 4 || nsError.code == 260 {
            return true
        }
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == Int(ENOENT) {
            return true
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain, underlying.code == Int(ENOENT) {
            return true
        }
        return false
    }
}
