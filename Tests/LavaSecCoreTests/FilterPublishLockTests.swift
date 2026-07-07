import Foundation
import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

final class FilterPublishLockTests: XCTestCase {
    func testExclusiveLockRunsBodyAndReturnsValue() throws {
        let lockURL = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        var ran = false
        let result = FilterPublishLock.withExclusiveLock(at: lockURL) { () -> Int in
            ran = true
            return 42
        }
        XCTAssertTrue(ran)
        XCTAssertEqual(result, 42)
    }

    func testExclusiveLockDegradesOpenWhenURLIsNil() {
        var ran = false
        FilterPublishLock.withExclusiveLock(at: nil) { ran = true }
        XCTAssertTrue(ran, "A nil lock URL must degrade-open and still run the body.")
    }

    func testTryExclusiveLockRunsWhenUncontended() throws {
        let lockURL = try makeLockURL()
        defer { try? FileManager.default.removeItem(at: lockURL.deletingLastPathComponent()) }

        let result: Int? = FilterPublishLock.withTryExclusiveLock(at: lockURL) { 7 }
        XCTAssertEqual(result, 7)
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

    /// Real cross-process contention: a `flock` exclusive lock is held by a separate
    /// process while we attempt the non-blocking acquire, which must DEGRADE-ABORT
    /// (return `nil`, body not run). This cannot be exercised in-process on Darwin —
    /// `flock` held by the same process via a different descriptor does not reliably
    /// conflict — so the holder is a child process, synchronized by file sentinels
    /// (no timing sleeps, so it is deterministic, not flaky).
    func testTryExclusiveLockAbortsWhenContendedByAnotherProcess() throws {
        let python = "/usr/bin/python3"
        guard FileManager.default.isExecutableFile(atPath: python) else {
            try skipVisibly("python3 unavailable; cross-process flock contention is covered by the device gate.")
            return
        }

        let lockURL = try makeLockURL()
        let dir = lockURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: dir) }
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

    private func makeLockURL() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("filter-publish-lock-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("filter-artifact-publish.lock")
    }
}
