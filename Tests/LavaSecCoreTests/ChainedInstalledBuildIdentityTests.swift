import Foundation
import XCTest

@testable import LavaSecKit

final class ChainedInstalledBuildIdentityTests: XCTestCase {
    func testDifferentExecutableBytesProduceDifferentBuildIdentities() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chained-build-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = directory.appendingPathComponent("first")
        let second = directory.appendingPathComponent("second")
        try Data("first tunnel binary".utf8).write(to: first)
        try Data("second tunnel binary".utf8).write(to: second)

        let firstIdentity = ChainedInstalledBuildIdentity.make(
            version: "1.3.0", build: "1", revision: "", executableURL: first)
        let secondIdentity = ChainedInstalledBuildIdentity.make(
            version: "1.3.0", build: "1", revision: "", executableURL: second)

        XCTAssertNotNil(firstIdentity)
        XCTAssertNotNil(secondIdentity)
        XCTAssertNotEqual(
            firstIdentity,
            secondIdentity,
            "distinct locally built tunnel binaries must never share crash-loop evidence")
    }

    func testSameExecutableBytesRemainStableAcrossProviderRestarts() throws {
        let executable = FileManager.default.temporaryDirectory
            .appendingPathComponent("chained-build-identity-\(UUID().uuidString)")
        try Data("same installed tunnel binary".utf8).write(to: executable)
        defer { try? FileManager.default.removeItem(at: executable) }

        let first = ChainedInstalledBuildIdentity.make(
            version: "1.3.0", build: "1", revision: "", executableURL: executable)
        let second = ChainedInstalledBuildIdentity.make(
            version: "1.3.0", build: "1", revision: "", executableURL: executable)

        XCTAssertEqual(first, second, "one installed binary must keep one identity across restarts")
    }

    func testUnreadableExecutableCannotFallBackToCollidingVersionOnlyIdentity() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-tunnel-\(UUID().uuidString)")

        XCTAssertNil(
            ChainedInstalledBuildIdentity.make(
                version: "1.3.0", build: "1", revision: "", executableURL: missing),
            "without exact binary identity, chained startup must fail closed")
    }
}
