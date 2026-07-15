import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable classification tests for the INV-PERSIST-1 reader: "existing but unreadable"
/// (Data Protection between reboot and first unlock, or transient I/O) must never collapse
/// into "absent" — that collapse is what wiped the filter library in the 2026-07-14
/// reboot-before-first-unlock incident. The unreadable case is reproduced portably with a
/// permission-denied file (chmod 000): same failing `Data(contentsOf:)` read + same intact
/// `fileExists` metadata probe as a protection-locked file on device.
final class SharedStateFileReaderTests: XCTestCase {
    private struct Payload: Codable, Equatable, Sendable {
        var name: String
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssfr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func skipIfRoot() throws {
        // Root bypasses POSIX permission checks, so the chmod-000 unreadable fixture would
        // read fine and mis-classify. CI runners execute as a regular user.
        try XCTSkipIf(geteuid() == 0, "chmod-based unreadable fixture requires a non-root user")
    }

    func testLoadedWhenFileDecodes() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("state.json")
        try JSONEncoder().encode(Payload(name: "kept")).write(to: url)

        guard case .loaded(let value) = SharedStateFileReader.read(Payload.self, from: url) else {
            return XCTFail("A decodable file must classify as .loaded")
        }
        XCTAssertEqual(value, Payload(name: "kept"))
    }

    func testAbsentWhenNoFileExists() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("missing.json")

        guard case .absent = SharedStateFileReader.read(Payload.self, from: url) else {
            return XCTFail("A missing file must classify as .absent — seeding is safe only here")
        }
    }

    func testCorruptWhenFileReadsButDoesNotDecode() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("garbage.json")
        try Data("not json {{".utf8).write(to: url)

        guard case .corrupt = SharedStateFileReader.read(Payload.self, from: url) else {
            return XCTFail("A readable-but-undecodable file must classify as .corrupt (reseed allowed)")
        }
    }

    func testUnreadableWhenFileExistsButContentReadIsDenied() throws {
        try skipIfRoot()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("locked.json")
        try JSONEncoder().encode(Payload(name: "intact-but-locked")).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        guard case .unreadable = SharedStateFileReader.read(Payload.self, from: url) else {
            return XCTFail("An existing file whose content read fails must classify as .unreadable, NEVER .absent")
        }
    }

    /// Privacy guard: the `.unreadable` description ships in the user-shareable bug-report bundle
    /// (`LavaSecDeviceDebugLog` "error" key → `BugReportBundle.allowedDetailKeys`), and it fires in
    /// the post-reboot pre-unlock window. The classification must carry only a coarse domain+code —
    /// never the raw `NSError` description, which on Apple platforms embeds the file's NSFilePath.
    func testUnreadableDescriptionCarriesNoFilesystemPath() throws {
        try skipIfRoot()
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // A distinctive filename: had the raw NSError description leaked through, the filename
        // (and its containing path) would appear in `description` and reach the wire.
        let secretName = "locked-secret-\(UUID().uuidString).json"
        let url = dir.appendingPathComponent(secretName)
        try JSONEncoder().encode(Payload(name: "intact-but-locked")).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        guard case .unreadable(let description) = SharedStateFileReader.read(Payload.self, from: url) else {
            return XCTFail("A locked file must classify as .unreadable.")
        }
        XCTAssertFalse(description.isEmpty,
                       "The unreadable description must still carry a coarse diagnostic (domain+code) to tell a lock from an I/O fault.")
        XCTAssertFalse(description.contains(secretName),
                       "The unreadable description must NOT contain the filename — it ships in bug reports.")
        XCTAssertFalse(description.contains(dir.path),
                       "The unreadable description must NOT contain the filesystem path.")
        XCTAssertFalse(description.contains("/"),
                       "A coarse domain+code descriptor contains no path separators; a '/' means a filesystem string leaked.")
    }

    func testFileExistsButIsUnreadableProbe() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Missing ⇒ false (a first write is normal).
        XCTAssertFalse(SharedStateFileReader.fileExistsButIsUnreadable(at: dir.appendingPathComponent("nope.json")))

        // Readable (even if corrupt for a decoder) ⇒ false — corruption recovery may overwrite.
        let readable = dir.appendingPathComponent("readable.json")
        try Data("junk".utf8).write(to: readable)
        XCTAssertFalse(SharedStateFileReader.fileExistsButIsUnreadable(at: readable))

        // Empty (zero-byte) file ⇒ false — the single-open probe succeeds, so it is readable,
        // not "unreadable" (guards against the open-based rewrite regressing on empty files).
        let empty = dir.appendingPathComponent("empty.json")
        try Data().write(to: empty)
        XCTAssertFalse(SharedStateFileReader.fileExistsButIsUnreadable(at: empty))

        // Existing with a denied content read ⇒ true — the writer fence must refuse.
        try skipIfRoot()
        let locked = dir.appendingPathComponent("locked.json")
        try Data("locked".utf8).write(to: locked)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
        XCTAssertTrue(SharedStateFileReader.fileExistsButIsUnreadable(at: locked))
    }
}
