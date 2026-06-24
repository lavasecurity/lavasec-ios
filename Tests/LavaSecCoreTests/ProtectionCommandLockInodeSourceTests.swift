import XCTest

/// Guards the cross-process protection-command lock against the inode-replacement
/// bug. `FileManager.createFile(atPath:)` on an existing file replaces its inode on
/// Darwin (temp + rename), and because `flock` locks are bound to the inode, calling
/// it before `open` would orphan the current holder's lock and let every acquirer
/// lock a brand-new inode — defeating mutual exclusion for the app/tunnel/widget
/// command channel. The lock must open the file with `open(O_CREAT)` only.
final class ProtectionCommandLockInodeSourceTests: XCTestCase {
    func testCommandLockOpensWithoutReplacingTheInode() throws {
        let source = try Self.source(named: "LavaProtectionCommandService.swift", in: "Shared")

        XCTAssertTrue(
            source.contains("open(lockURL.path, O_CREAT | O_RDWR"),
            "The command lock must open the lock file with open(O_CREAT) so all processes share one inode."
        )
        XCTAssertFalse(
            source.contains("createFile(atPath: lockURL.path"),
            "FileManager.createFile replaces the inode on Darwin, defeating flock's cross-process mutual exclusion."
        )
    }

    // MARK: - Source introspection helpers

    private static func source(named fileName: String, in directoryName: String) throws -> String {
        let testFileURL = URL(fileURLWithPath: #filePath)
        let packageRootURL = testFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceURL = packageRootURL
            .appendingPathComponent(directoryName)
            .appendingPathComponent(fileName)

        return try String(contentsOf: sourceURL, encoding: .utf8)
    }
}
