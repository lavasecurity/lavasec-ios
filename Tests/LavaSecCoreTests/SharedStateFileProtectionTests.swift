import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable tests for the INV-PERSIST-2 protection-class helper. The iOS-only halves
/// (the Class-None writing option, `.protectionKey`) cannot execute on the macOS CI host — those
/// call sites are covered by `ControlPlaneProtectionSourceTests` pins — so these tests
/// lock the OFF-iOS fallbacks (the exact surface the package's macOS compile exercises)
/// and the platform-independent atomic write semantics.
final class SharedStateFileProtectionTests: XCTestCase {
    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ssfp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testNonIOSPlatformsKeepPlainAtomicWritesAndReportProtectionApplied() throws {
        #if os(iOS)
        throw XCTSkip("Off-iOS fallback surface; on iOS the options carry Class-None by design.")
        #else
        // The macOS compile must degrade to exactly the pre-INV-PERSIST-2 behavior:
        // atomic-only options, no creation attributes, and a vacuously-true apply — so
        // package code funneling through the helper builds and behaves on the CI host.
        XCTAssertEqual(SharedStateFileProtection.atomicControlPlaneWritingOptions, [.atomic])
        XCTAssertNil(SharedStateFileProtection.controlPlaneCreationAttributes)

        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("existing.json")
        try Data("{}".utf8).write(to: url)
        XCTAssertTrue(
            SharedStateFileProtection.applyControlPlaneProtection(at: url),
            "Off-iOS there is no protection class to change, so apply must report success (never blocks the migration latch)."
        )
        #endif
    }

    func testAtomicControlPlaneWritingOptionsRoundTripBytes() throws {
        // On every platform the options must stay a working atomic write — .atomic is
        // load-bearing for torn-write safety across the three writer processes.
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("control-plane.bin")
        let payload = Data("control-plane payload \(UUID().uuidString)".utf8)

        try payload.write(to: url, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)

        XCTAssertEqual(try Data(contentsOf: url), payload)
    }
}
