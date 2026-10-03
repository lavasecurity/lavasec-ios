import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterPublishLockTests: XCTestCase {
    func testExclusiveLockRunsBodyAndReturnsValue() throws {
        try withTemporaryDirectory(prefix: "filter-publish-lock-tests") { temporaryDirectory in
            let lockURL = temporaryDirectory.appendingPathComponent("filter-artifact-publish.lock")

            var ran = false
            let result = FilterPublishLock.withExclusiveLock(at: lockURL) { () -> Int in
                ran = true
                return 42
            }
            XCTAssertTrue(ran)
            XCTAssertEqual(result, 42)
        }
    }

    func testExclusiveLockDegradesOpenWhenURLIsNil() {
        var ran = false
        FilterPublishLock.withExclusiveLock(at: nil) { ran = true }
        XCTAssertTrue(ran, "A nil lock URL must degrade-open and still run the body.")
    }

    func testTryExclusiveLockRunsWhenUncontended() throws {
        try withTemporaryDirectory(prefix: "filter-publish-lock-tests") { temporaryDirectory in
            let lockURL = temporaryDirectory.appendingPathComponent("filter-artifact-publish.lock")

            let result: Int? = FilterPublishLock.withTryExclusiveLock(at: lockURL) { 7 }
            XCTAssertEqual(result, 7)
        }
    }

    func testTryExclusiveLockAbortsWhenURLIsNil() {
        var ran = false
        let result: Int? = FilterPublishLock.withTryExclusiveLock(at: nil) { () -> Int in
            ran = true
            return 1
        }
        XCTAssertNil(result)
        XCTAssertFalse(ran, "Background writers degrade-ABORT, never degrade-open, on an unavailable lock.")
    }

    func testARequiredExclusiveLockRunsBodyWhenExclusionIsEstablished() throws {
        try withTemporaryDirectory(prefix: "filter-publish-lock-tests") { temporaryDirectory in
            let lockURL = temporaryDirectory.appendingPathComponent("chained-upstream-write.lock")

            var ran = false
            let result = FilterPublishLock.withRequiredExclusiveLock(at: lockURL) { () -> Int in
                ran = true
                return 9
            }
            XCTAssertTrue(ran)
            XCTAssertEqual(result, 9)
        }
    }

    func testARequiredExclusiveLockRefusesRatherThanRunningUnlocked() throws {
        // The distinction from `withExclusiveLock`, which returns `try body()` from BOTH of
        // its guards. A caller whose body deletes key material cannot use that: an unlocked
        // delete is durable and there is no backup or sync copy to recover from.
        var ranWithoutURL = false
        let withoutURL: Int? = FilterPublishLock.withRequiredExclusiveLock(at: nil) { () -> Int in
            ranWithoutURL = true
            return 1
        }
        XCTAssertNil(withoutURL)
        XCTAssertFalse(ranWithoutURL, "a nil lock URL must refuse, never degrade-open")

        try withTemporaryDirectory(prefix: "filter-publish-lock-tests") { temporaryDirectory in
            let lockURL = temporaryDirectory.appendingPathComponent("chained-upstream-write.lock")
            // A lock file that exists but cannot be opened `O_RDWR` — the second way
            // `openLockDescriptor` returns `nil` in the field (the first is a container the
            // process cannot write). Asserted rather than assumed: a user for whom mode bits
            // do not apply would otherwise take the LOCKED path and pass vacuously.
            FileManager.default.createFile(atPath: lockURL.path, contents: nil)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o000], ofItemAtPath: lockURL.path)
            defer {
                try? FileManager.default.setAttributes(
                    [.posixPermissions: 0o600], ofItemAtPath: lockURL.path)
            }
            if let descriptor = FilterPublishLock.openLockDescriptor(at: lockURL) {
                close(descriptor)
                throw XCTSkip("this user can open a 000-mode file; the fixture cannot be staged")
            }

            var ran = false
            let result: Int? = FilterPublishLock.withRequiredExclusiveLock(at: lockURL) { () -> Int in
                ran = true
                return 1
            }
            XCTAssertNil(result)
            XCTAssertFalse(ran, "an unopenable lock file must refuse, never degrade-open")
        }
    }

    /// Real cross-process contention: a `flock` exclusive lock is held by a separate
    /// process while we attempt the non-blocking acquire, which must DEGRADE-ABORT
    /// (return `nil`, body not run). This cannot be exercised in-process on Darwin —
    /// `flock` held by the same process via a different descriptor does not reliably
    /// conflict — so the holder is a child process, synchronized by file sentinels
    /// (no timing sleeps, so it is deterministic, not flaky).
    func testTryExclusiveLockAbortsWhenContendedByAnotherProcess() throws {
        try withTemporaryDirectory(prefix: "filter-publish-lock-tests") { temporaryDirectory in
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                try skipVisibly("python3 unavailable; cross-process flock contention is covered by the device gate.")
                return
            }

            let lockURL = temporaryDirectory.appendingPathComponent("filter-artifact-publish.lock")
            let dir = lockURL.deletingLastPathComponent()
            let readyURL = dir.appendingPathComponent("ready")
            let releaseURL = dir.appendingPathComponent("release")

            // Holder: acquire LOCK_EX, signal ready, hold until the release sentinel appears.
            let script = """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            open(sys.argv[2], "w").close()
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
            """
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: python)
            holder.arguments = ["-c", script, lockURL.path, readyURL.path, releaseURL.path]
            try holder.run()
            defer {
                FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
                holder.waitUntilExit()
            }

            // Wait (bounded) for the child to actually hold the lock. The loop exits as soon as
            // the sentinel appears, so the generous deadline costs nothing in the common case.
            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
                usleep(10_000)
            }
            guard FileManager.default.fileExists(atPath: readyURL.path) else {
                try skipVisibly("holder process did not acquire the lock within 20s")
                return
            }

            var ran = false
            let result: Int? = FilterPublishLock.withTryExclusiveLock(at: lockURL) { () -> Int in
                ran = true
                return 1
            }
            XCTAssertNil(result, "A cross-process-contended non-blocking acquire must abort.")
            XCTAssertFalse(ran, "The body must NOT run when another process holds the lock (degrade-ABORT).")
        }
    }

    /// THE SINGLE-FLIGHT PRIMITIVE, under real cross-process contention.
    ///
    /// The closure-scoped variants cannot express a lock held across a suspension point — a
    /// `defer` inside a synchronous closure unwinds when the closure returns, not when an `async`
    /// caller's work finishes — so the background warm pass needs the descriptor itself
    /// (`AppViewModel.warmNonActiveFiltersInBackground`, PR #646). Same degrade-ABORT contract:
    /// `nil` means "someone else owns this", never "proceed unlocked".
    func testAHeldDescriptorExcludesASecondTryAcquire() throws {
        try withTemporaryDirectory(prefix: "warm-index-lock-tests") { temporaryDirectory in
            let python = "/usr/bin/python3"
            guard FileManager.default.isExecutableFile(atPath: python) else {
                try skipVisibly("python3 unavailable; cross-process flock contention is covered by the device gate.")
                return
            }

            let lockURL = temporaryDirectory.appendingPathComponent("background-warm-index.lock")
            let dir = lockURL.deletingLastPathComponent()
            let readyURL = dir.appendingPathComponent("ready")
            let releaseURL = dir.appendingPathComponent("release")

            let script = """
            import fcntl, os, sys, time
            fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o600)
            fcntl.flock(fd, fcntl.LOCK_EX)
            open(sys.argv[2], "w").close()
            while not os.path.exists(sys.argv[3]):
                time.sleep(0.01)
            """
            let holder = Process()
            holder.executableURL = URL(fileURLWithPath: python)
            holder.arguments = ["-c", script, lockURL.path, readyURL.path, releaseURL.path]
            try holder.run()
            defer {
                FileManager.default.createFile(atPath: releaseURL.path, contents: nil)
                holder.waitUntilExit()
            }

            let deadline = Date().addingTimeInterval(20)
            while !FileManager.default.fileExists(atPath: readyURL.path), Date() < deadline {
                usleep(10_000)
            }
            guard FileManager.default.fileExists(atPath: readyURL.path) else {
                try skipVisibly("holder process did not acquire the lock within 20s")
                return
            }

            XCTAssertNil(
                FilterPublishLock.tryAcquireExclusiveDescriptor(at: lockURL),
                "a contended acquire must return nil — a second warm pass proceeding here would "
                    + "recompute from the same prior state and drop the holder's staged entries")
        }
    }

    /// ...and it succeeds when nothing holds the lock, then releases cleanly so the NEXT pass can
    /// acquire. A release that did not actually unlock would wedge every later run in-process.
    func testAReleasedDescriptorLetsTheNextAcquireSucceed() throws {
        try withTemporaryDirectory(prefix: "warm-index-lock-tests") { temporaryDirectory in
            let lockURL = temporaryDirectory.appendingPathComponent("background-warm-index.lock")

            let first = try XCTUnwrap(
                FilterPublishLock.tryAcquireExclusiveDescriptor(at: lockURL),
                "an uncontended acquire must succeed")
            FilterPublishLock.releaseDescriptor(first)

            let second = try XCTUnwrap(
                FilterPublishLock.tryAcquireExclusiveDescriptor(at: lockURL),
                "the lock must be free again after release")
            FilterPublishLock.releaseDescriptor(second)
        }
    }

    /// A nil lock URL is degrade-ABORT, never degrade-open. The warm pass rewrites the sidecar
    /// wholesale, so "could not lock" must mean "do not run", not "run unprotected".
    func testAcquiringWithoutALockURLRefuses() {
        XCTAssertNil(FilterPublishLock.tryAcquireExclusiveDescriptor(at: nil))
    }

    /// This is the ONLY in-lane proof that cross-process `flock` contention degrade-ABORTs.
    /// On CI the runner image is pinned, so either skip condition (python3 missing, holder
    /// wedged) is an environment regression that would otherwise retire the proof silently —
    /// fail loud there. Locally it stays a visible skip.
    private func skipVisibly(_ reason: String, file: StaticString = #filePath, line: UInt = #line) throws {
        if ProcessInfo.processInfo.environment["CI"] == "true" {
            XCTFail("cross-process flock proof would silently stop running on CI: \(reason)", file: file, line: line)
            return
        }
        throw XCTSkip(reason)
    }

}
