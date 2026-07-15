import XCTest
@testable import LavaSecCore
@testable import LavaSecKit

/// Executable tests for the INV-PERSIST-2 reseed-suppression marker store. The marker's
/// EXISTENCE encodes the launch-reseed automatic-backup suppression; it replaced a Class-C
/// `UserDefaults` marker whose locked read returned a spurious `false` and whose write could
/// not land durably pre-first-unlock (Codex P1 + Kilo/OCR follow-up on the 1.2.4 sync). The
/// Class-None protection class itself is iOS-only (source-pinned in
/// `ControlPlaneProtectionSourceTests`); these tests lock the platform-independent
/// existence / mark / clear semantics the app-side wiring depends on.
final class ReseedSuppressionMarkerStoreTests: XCTestCase {
    private func makeTempContainer() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reseed-marker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testMarkIsReadableAndClearable() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        // Absent by default: a fresh container reads as unmarked.
        XCTAssertFalse(ReseedSuppressionMarkerStore.isMarked(containerURL: container),
                       "A fresh container must read as unmarked.")

        // Marking lands the marker file, and isMarked observes it via a metadata-only probe.
        XCTAssertTrue(ReseedSuppressionMarkerStore.mark(containerURL: container),
                      "mark must report the marker is on disk.")
        XCTAssertTrue(ReseedSuppressionMarkerStore.isMarked(containerURL: container),
                      "The marker must read back as present.")
        // Existence is the whole signal — the content is deliberately empty.
        let markerURL = ReseedSuppressionMarkerStore.markerURL(containerURL: container)
        XCTAssertEqual(try Data(contentsOf: markerURL), Data(),
                       "The marker's content is deliberately empty — only existence matters.")

        // Clearing removes it, and isMarked observes the absence.
        ReseedSuppressionMarkerStore.clear(containerURL: container)
        XCTAssertFalse(ReseedSuppressionMarkerStore.isMarked(containerURL: container),
                       "A cleared marker must read back as absent.")
    }

    func testMarkIsDurableAndIdempotent() throws {
        let container = try makeTempContainer()
        defer { try? FileManager.default.removeItem(at: container) }

        // First stamp lands the file — durability means on disk, not an in-memory flag.
        XCTAssertTrue(ReseedSuppressionMarkerStore.mark(containerURL: container))
        let markerURL = ReseedSuppressionMarkerStore.markerURL(containerURL: container)
        XCTAssertTrue(FileManager.default.fileExists(atPath: markerURL.path),
                      "The stamp must land the marker file on disk.")

        // Idempotent as a NO-WRITE: a present marker is short-circuited, never re-written.
        // Prove it by planting a sentinel byte at the marker path — a re-stamp that rewrote
        // the file would truncate it to empty; the surviving sentinel shows mark left it as-is.
        // (The app re-stamps on every reseed-accept; the short-circuit avoids that churn and
        // guarantees a second stamp cannot disturb an already-durable marker.)
        try Data([0x01]).write(to: markerURL, options: .atomic)
        XCTAssertTrue(ReseedSuppressionMarkerStore.mark(containerURL: container),
                      "A second stamp over a present marker must report success idempotently.")
        XCTAssertEqual(try Data(contentsOf: markerURL), Data([0x01]),
                       "A present marker must be left as-is (short-circuited), never re-written.")

        // Clear is idempotent: clearing an already-absent marker is a silent no-op, so a
        // double user-authoritative clear (e.g. restore then onboarding seed) cannot throw.
        ReseedSuppressionMarkerStore.clear(containerURL: container)
        XCTAssertFalse(ReseedSuppressionMarkerStore.isMarked(containerURL: container))
        ReseedSuppressionMarkerStore.clear(containerURL: container)
        XCTAssertFalse(ReseedSuppressionMarkerStore.isMarked(containerURL: container),
                       "Clearing an absent marker must remain a no-op, not resurrect or error.")
    }

    /// `clear` mirrors `mark`'s confirmed-on-disk contract: it returns whether the marker is now
    /// ABSENT, so a caller can keep the in-memory suppression flag consistent with a stuck durable
    /// marker instead of silently reporting the suppression lifted while the file survives on disk
    /// (OCR P1 on the 1.2.5 sync).
    func testClearReportsWhetherTheMarkerIsGone() throws {
        let container = try makeTempContainer()
        defer {
            // Restore write perms so the container tree can be torn down.
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: container.path)
            try? FileManager.default.removeItem(at: container)
        }

        // Absent marker → success (idempotent no-op).
        XCTAssertTrue(ReseedSuppressionMarkerStore.clear(containerURL: container),
                      "Clearing an absent marker must report success.")

        // Present marker → removed, success.
        XCTAssertTrue(ReseedSuppressionMarkerStore.mark(containerURL: container))
        XCTAssertTrue(ReseedSuppressionMarkerStore.clear(containerURL: container),
                      "Clearing a present marker must remove it and report success.")
        XCTAssertFalse(ReseedSuppressionMarkerStore.isMarked(containerURL: container))

        // Failed durable remove → false, and the marker stays put so the next launch re-derives the
        // suppression. Reproduce the failure by revoking WRITE on the container dir (removeItem must
        // write the parent). Root bypasses POSIX permission checks, so skip there.
        try XCTSkipIf(geteuid() == 0, "read-only-parent removal-failure fixture requires a non-root user")
        XCTAssertTrue(ReseedSuppressionMarkerStore.mark(containerURL: container))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: container.path)
        XCTAssertFalse(ReseedSuppressionMarkerStore.clear(containerURL: container),
                       "A remove that fails (read-only parent) must report false — the marker is still on disk.")
        XCTAssertTrue(ReseedSuppressionMarkerStore.isMarked(containerURL: container),
                      "The stuck marker must remain so the next launch re-derives the suppression.")
    }
}
