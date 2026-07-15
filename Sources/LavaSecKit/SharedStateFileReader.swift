import Foundation

/// Outcome of reading a shared-state file with Data-Protection awareness (INV-PERSIST-1).
///
/// After a device reboot, app-group files carry the iOS default protection class
/// (`NSFileProtectionCompleteUntilFirstUserAuthentication`), so between boot and the first
/// passcode unlock a content read fails even though the user's data is intact on disk. A
/// reader that collapses that failure into "no data" and then seeds-and-persists defaults
/// destroys the real state at a winning generation — the 2026-07-14 filter-library wipe
/// (lavasec-infra `plans/2026-07-14-reboot-first-unlock-data-reset-incident-plan.md`).
/// This type is the single classifier that keeps "locked right now" distinguishable from
/// "genuinely absent", so seed/migrate recovery can stay confined to the definitive cases.
public enum SharedStateFileReadOutcome<Value: Sendable>: Sendable {
    /// The file existed, was readable, and decoded.
    case loaded(Value)
    /// No file exists at the URL — first launch, or genuinely deleted. Seeding is safe.
    case absent
    /// The file was read successfully but did not decode — real corruption. Reseeding is
    /// the pre-existing, deliberate recovery for this case.
    case corrupt
    /// The file EXISTS but its content could not be read (Data Protection before first
    /// unlock, or a transient I/O failure). The user's data is likely intact — callers
    /// must treat state as unavailable and must NOT seed or persist defaults over it
    /// (INV-PERSIST-1). Carries only a COARSE breadcrumb — the underlying error's NSError
    /// domain+code — never the full description, which embeds the file path and would leak
    /// into the bug-report bundle (see `read(_:from:)`).
    case unreadable(description: String)
}

/// Data-Protection-aware shared-state file reads (INV-PERSIST-1). See
/// ``SharedStateFileReadOutcome`` for why "unreadable" must never collapse into "absent".
public enum SharedStateFileReader {
    /// Read and JSON-decode `url` into `type`, classifying every failure mode.
    ///
    /// Existence is probed via file METADATA (`fileExists`), which stays readable while
    /// content is protection-locked — that asymmetry is what makes `.absent` vs
    /// `.unreadable` reliably distinguishable before first unlock. A file that appears
    /// between the failed read and the probe classifies as `.unreadable` — the
    /// conservative side (never invites a seed over data).
    public static func read<Value: Decodable & Sendable>(
        _ type: Value.Type,
        from url: URL,
        fileManager: FileManager = .default
    ) -> SharedStateFileReadOutcome<Value> {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            guard fileManager.fileExists(atPath: url.path) else {
                return .absent
            }
            // Carry ONLY the NSError domain+code — NEVER `String(describing: error)`. On iOS the
            // full description of a `Data(contentsOf:)` failure embeds the file's NSFilePath
            // (…/AppGroup/<UUID>/filter-library.json) in the NSError userInfo, and callers route
            // this string into `LavaSecDeviceDebugLog` whose `error` detail key ships in the
            // user-shareable bug-report bundle (`BugReportBundle.allowedDetailKeys`) — precisely in
            // the high-sensitivity post-reboot pre-unlock window this classification fires in.
            // Domain+code still distinguishes a Data-Protection lock (Cocoa 257 / POSIX EPERM) from a
            // real I/O fault — the reason the outcome is diagnosable at all — with nothing
            // filesystem-derived reaching the wire.
            // pinned: SharedStateFileReaderTests.testUnreadableDescriptionCarriesNoFilesystemPath
            let nsError = error as NSError
            return .unreadable(description: "\(nsError.domain) \(nsError.code)")
        }
        guard let value = try? JSONDecoder().decode(Value.self, from: data) else {
            return .corrupt
        }
        return .loaded(value)
    }

    /// Whether `url` names a file that exists but whose CONTENT cannot currently be read
    /// (Data Protection before first unlock, or a transient I/O failure).
    ///
    /// Writer-side guard for INV-PERSIST-1: replacing a file you cannot read means you
    /// cannot know what you are destroying, so the shared-state writer refuses the write
    /// instead. Readable-but-corrupt files return `false` — overwriting those is the
    /// deliberate corruption recovery.
    public static func fileExistsButIsUnreadable(
        at url: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        // Attempt the CONTENT read first, then classify — the same open+read ordering as
        // `read`, so the two never diverge: whatever `read` classifies `.unreadable` (a
        // Data-Protection-locked Class-C file whose open OR decrypt fails before first unlock),
        // this treats as unreadable too. A single-`open(2)` probe would instead key only on the
        // open succeeding, which for a locked Class-C file can PRECEDE the read failure —
        // returning "readable" for a locked file and reopening the INV-PERSIST-1 wipe window
        // (Kilo review on the 1.2.4 sync; CI's chmod-000 fixture cannot reproduce
        // Data-Protection locking). Reading first also closes the stat→read window the old
        // `fileExists`-then-read form had: the metadata probe now runs only AFTER a failed
        // read, so a file a concurrent writer created mid-probe reads as existing → unreadable,
        // the conservative side (matching `read`). The shared-state callers additionally hold
        // `FilterPublishLock.withExclusiveLock`.
        //
        // FROZEN (INV-PERSIST-1): this MUST stay a raw `Data(contentsOf:)` with DEFAULT options —
        // same for the read in `read(_:from:)` above. A Data-Protection-locked Class-C file throws
        // on the open+read before first unlock; any wrapper that adds options (`.alwaysMapped`,
        // `.mappedIfSafe`, NSData bridging, or a future "auto-handle protection" API) can turn that
        // throw into a successful-but-stale/zero read, the classifier returns `.loaded`/`.corrupt`,
        // and the 2026-07-14 wipe window silently re-opens. The chmod-000 test fixture cannot
        // reproduce Data-Protection locking, so a regression here is NOT caught by CI — do not add
        // options.
        if (try? Data(contentsOf: url)) != nil {
            // Readable right now (a readable-but-corrupt file included — overwriting it is the
            // deliberate corruption recovery).
            return false
        }
        // The read failed: an existing file whose content cannot be read now is unreadable (the
        // writer fence must refuse); genuinely absent is `false` (a first write is safe).
        return fileManager.fileExists(atPath: url.path)
    }
}
