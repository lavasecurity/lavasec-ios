import Foundation

/// Cross-process advisory publish lock for the shared filter-artifact set, mirroring
/// `LavaProtectionCommandFileLock` (`Shared/LavaProtectionCommandService.swift`).
///
/// In the pointer-swap design (LAV-90 Phase 1) this lock is the **writer-vs-writer**
/// exclusion mechanism ONLY — readers follow the atomically-swapped pointer and stay
/// lock-free. Semantics match the BSD `flock(2)` the codebase already relies on:
/// advisory, auto-released on `close`/process death, so a crashed holder never wedges
/// the lock and no stale-lock recovery is needed.
///
/// `LavaSecCore` has no App-Group constants, so the lock file is named by the caller:
/// app and tunnel both pass a URL derived from
/// `LavaSecAppGroup.filterArtifactPublishLockFilename`.
public enum FilterPublishLock {
    /// Run `body` while holding an exclusive (`LOCK_EX`) advisory lock on `lockURL`.
    ///
    /// Foreground writers use this: it BLOCKS until the lock is free (the user is
    /// waiting and foreground must win) and DEGRADES-OPEN — if `lockURL` is `nil` or
    /// the file cannot be opened/locked, `body` still runs unlocked, exactly like the
    /// existing protection-command helper. The fail-closed gate on the read side
    /// remains the real safety boundary; this lock is an optimization, never the
    /// guarantee.
    @discardableResult
    public static func withExclusiveLock<T>(
        at lockURL: URL?,
        _ body: () throws -> T
    ) rethrows -> T {
        guard let lockURL, let descriptor = openLockDescriptor(at: lockURL) else {
            return try body()
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            return try body()
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    /// Run `body` while holding an exclusive (`LOCK_EX`) advisory lock on `lockURL`, or
    /// return `nil` WITHOUT running it.
    ///
    /// BLOCKING like ``withExclusiveLock(at:_:)`` — a foreground writer waits out a
    /// contending writer instead of failing a save the user is watching — but FAIL-CLOSED
    /// like ``withTryExclusiveLock(at:_:)``: if `lockURL` is `nil`, the file cannot be
    /// opened, or `flock` fails, `body` does not run and the caller gets `nil` to turn
    /// into whatever refusal its vocabulary already has.
    ///
    /// The third variant exists rather than a fourth argument to the first because the two
    /// degrade policies answer different questions, and the filter-publish caller's answer
    /// is not transferable. There, `body` republishes artifacts a fail-closed READ gate
    /// re-validates, so running unlocked risks a redundant publish; the lock is an
    /// optimization and says so. A caller whose `body` DELETES key material has no such
    /// gate behind it — an unlocked delete is durable and unrecoverable — so for it
    /// exclusion is the guarantee, not the optimization.
    /// pinned: FilterPublishLockTests.testARequiredExclusiveLockRefusesRatherThanRunningUnlocked
    public static func withRequiredExclusiveLock<T>(
        at lockURL: URL?,
        _ body: () throws -> T
    ) rethrows -> T? {
        guard let lockURL, let descriptor = openLockDescriptor(at: lockURL) else {
            return nil
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX) == 0 else {
            return nil
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    /// Try to run `body` while holding a non-blocking exclusive lock
    /// (`LOCK_EX | LOCK_NB`).
    ///
    /// Background writers use this: if the lock is contended (a foreground writer
    /// holds it) OR the lock file is unavailable, this returns `nil` WITHOUT running
    /// `body` — DEGRADE-ABORT, never degrade-open, so a stale background publish can
    /// never clobber. `body` runs (and its result is returned) only when the lock was
    /// cleanly acquired.
    public static func withTryExclusiveLock<T>(
        at lockURL: URL?,
        _ body: () throws -> T
    ) rethrows -> T? {
        guard let lockURL, let descriptor = openLockDescriptor(at: lockURL) else {
            return nil
        }
        defer { close(descriptor) }

        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            return nil
        }
        defer { flock(descriptor, LOCK_UN) }

        return try body()
    }

    /// Open (creating if needed) the advisory lock file, returning its descriptor or
    /// `nil` on failure. Exposed for callers (e.g. test harnesses) that need to hold
    /// the lock fd directly. The caller owns `close`.
    ///
    /// Uses `open(O_CREAT)` only — deliberately NOT `FileManager.createFile`, which on
    /// Darwin replaces the file's inode when it already exists. Because `flock` locks
    /// are bound to the inode, replacing it would let every acquirer lock a fresh
    /// inode and silently never contend with the current holder, defeating the lock.
    /// `O_CREAT` without `O_TRUNC`/`O_EXCL` opens the existing inode (or creates one),
    /// so all processes share a single lock object.
    public static func openLockDescriptor(at lockURL: URL) -> Int32? {
        let descriptor = open(lockURL.path, O_CREAT | O_RDWR, mode_t(S_IRUSR | S_IWUSR))
        return descriptor >= 0 ? descriptor : nil
    }

    /// Try to take a non-blocking exclusive lock and RETURN the held descriptor, or `nil` if the
    /// lock is contended or unavailable.
    ///
    /// The closure-scoped variants above cannot express a lock held across a suspension point: a
    /// `defer { flock(...) }` inside a synchronous closure unwinds when the closure returns, not
    /// when an `async` caller's work finishes. A single-flight around an `await`-ing pass therefore
    /// needs the descriptor itself. Degrade-ABORT like ``withTryExclusiveLock(at:_:)`` — a `nil`
    /// return means "someone else owns this", never "proceed unlocked".
    ///
    /// The caller MUST pair this with ``releaseDescriptor(_:)``, and must not let the descriptor
    /// escape the scope that releases it. `flock` is released by the kernel on process death, so a
    /// caller killed mid-pass (a jetsammed BGTask) cannot wedge the lock for the next launch.
    /// pinned: FilterPublishLockTests.testAHeldDescriptorExcludesASecondTryAcquire
    public static func tryAcquireExclusiveDescriptor(at lockURL: URL?) -> Int32? {
        guard let lockURL, let descriptor = openLockDescriptor(at: lockURL) else {
            return nil
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    /// Release and close a descriptor obtained from ``tryAcquireExclusiveDescriptor(at:)``.
    public static func releaseDescriptor(_ descriptor: Int32) {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
}
