import Foundation
import XCTest
import LavaSecAppServices

final class PrivateImportFilesTests: XCTestCase {
    func testCopyIsOwnedAndExpiryNeverDeletesUnrelatedTemporaryFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("someone-elses-file")
        let bytes = Data("private QR input".utf8)
        try bytes.write(to: source)
        let copy = try PrivateImportFiles.copy(source, into: directory)
        XCTAssertEqual(try Data(contentsOf: copy), bytes)
        XCTAssertTrue(copy.lastPathComponent.hasPrefix("lava-private-import-"))
        #if os(iOS)
        let protection = try FileManager.default.attributesOfItem(atPath: copy.path)[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .complete)
        #endif
        PrivateImportFiles.purgeExpired(in: directory)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.path))
        PrivateImportFiles.purgeExpired(in: directory, now: Date().addingTimeInterval(3601))
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testFailedSourceReadLeavesNoAbandonedImport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        XCTAssertThrowsError(try PrivateImportFiles.copy(directory.appendingPathComponent("missing"), into: directory))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}
