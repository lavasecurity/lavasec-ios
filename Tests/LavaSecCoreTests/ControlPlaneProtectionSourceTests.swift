import XCTest
@testable import LavaSecCore

/// Pins the INV-PERSIST-2 wiring the compiler can't see: every control-plane writer must
/// funnel its protection class through `SharedStateFileProtection` (a raw `[.atomic]`
/// write silently reverts that file to Class C, resurrecting the pre-unlock fail-closed
/// boot for exactly that file), the streaming compiler must stamp its scratch at creation
/// and re-stamp after promotion, and the app must trigger the one-shot migration
/// post-unlock. The helper's platform behavior itself is executable-tested in
/// `SharedStateFileProtectionTests` / `ControlPlaneProtectionMigrationTests`.
final class ControlPlaneProtectionSourceTests: XCTestCase {
    private let optionsMarker = "options: SharedStateFileProtection.atomicControlPlaneWritingOptions"
    private let rawAtomicMarker = "options: [.atomic]"

    func testSharedPairWriterStampsControlPlaneWritingOptions() throws {
        let writer = try readSource(.sharedFilterStatePersistence)
        // Exactly the three physical pair writes (two library sides + one config; their
        // count/order is pinned by SharedConfigurationWriterInvariantSourceTests and
        // MultiFilterFoundationSourceTests) — all through the helper, none raw.
        XCTAssertEqual(sourceOccurrenceCount(of: optionsMarker, in: writer), 3,
                       "All three pair writes must carry the control-plane protection options (INV-PERSIST-2).")
        XCTAssertEqual(sourceOccurrenceCount(of: rawAtomicMarker, in: writer), 0,
                       "A raw [.atomic] pair write would land Class C and defeat the pre-unlock boot read.")
    }

    func testArtifactStoreWritesStampControlPlaneWritingOptions() throws {
        let store = try readSource(.filterArtifactStore)
        // Manifest + prepared + compact — the trio the boot tunnel reads.
        XCTAssertEqual(sourceOccurrenceCount(of: optionsMarker, in: store), 3,
                       "All three artifact writes must carry the control-plane protection options (INV-PERSIST-2).")
        XCTAssertEqual(sourceOccurrenceCount(of: rawAtomicMarker, in: store), 0,
                       "A raw [.atomic] artifact write would land Class C and defeat the pre-unlock boot read.")
    }

    func testArtifactPointerWriteStampsControlPlaneWritingOptions() throws {
        let versioned = try readSource(.filterArtifactStoreVersioned)
        XCTAssertEqual(sourceOccurrenceCount(of: optionsMarker, in: versioned), 1,
                       "The publish pointer is the boot tunnel's first read; its write must carry the control-plane options (INV-PERSIST-2).")
        XCTAssertEqual(sourceOccurrenceCount(of: rawAtomicMarker, in: versioned), 0,
                       "A raw [.atomic] pointer write would land Class C and defeat every readable artifact behind it.")
    }

    func testTunnelHealthWriteStampsControlPlaneWritingOptions() throws {
        let provider = try readSource(.packetTunnelProvider)
        let healthWriteBlock = try sourceBlock(
            in: provider,
            startingAt: "private lazy var healthPersistence = DebouncedPersistenceController(",
            endingBefore: "private lazy var diagnosticsPersistence = DebouncedPersistenceController("
        )
        XCTAssertTrue(healthWriteBlock.contains("LavaSecAppGroup.tunnelHealthFilename"),
                      "The pinned block must still be the tunnel-health write closure.")
        // Count + write-site anchor, not a bare contains: a comment or debug-log mention of the
        // options marker inside this block would otherwise pass vacuously while a regression
        // dropped the options from the real write (OCR follow-up on the 1.2.4 sync).
        XCTAssertEqual(sourceOccurrenceCount(of: optionsMarker, in: healthWriteBlock), 1,
                       "Exactly one control-plane options marker, at the health write site (INV-PERSIST-2).")
        XCTAssertTrue(
            healthWriteBlock.contains("data.write(to: url, \(optionsMarker))"),
            "The boot tunnel writes health pre-unlock; the options marker must sit at the real Data.write call — a Class-C write fails silently under this closure's try? (INV-PERSIST-2).")
    }

    func testStreamingCompilerStampsScratchAtCreationAndReappliesAfterPromotion() throws {
        let compiler = try readSource(.streamingCompactSnapshotCompiler)
        // Both scratch files (blob + output) must be Class-None at CREATION — the
        // same-volume rename promotion inherits the scratch file's class.
        XCTAssertEqual(
            sourceOccurrenceCount(
                of: "attributes: SharedStateFileProtection.controlPlaneCreationAttributes",
                in: compiler
            ),
            2,
            "Both createFile calls (blob + output) must stamp the control-plane creation attributes (INV-PERSIST-2)."
        )
        // …and the promotion must NOT preserve destination metadata: replaceItemAt can
        // carry a pre-INV-PERSIST-2 Class-C class onto the replaced item, and a post-hoc
        // re-stamp can FAIL before first unlock (re-classing re-encrypts, needing the
        // locked class key) — remove+move makes the promoted file carry the scratch
        // Class-None from creation, unconditionally (PR #378 review).
        XCTAssertFalse(
            compiler.contains("replaceItemAt("),
            "No metadata-preserving promotion — it can resurrect a Class-C retained artifact that a pre-unlock re-stamp cannot fix."
        )
        XCTAssertTrue(
            sourceContainsInOrder([
                "removeItem(at: retainedArtifactURL)",
                "moveItem(at: outputURL, to: retainedArtifactURL)",
                "SharedStateFileProtection.applyControlPlaneProtection(at: retainedArtifactURL)",
            ], in: compiler),
            "Promotion must be remove+move (scratch class carried from creation) with the belt-and-braces re-stamp after (INV-PERSIST-2)."
        )
    }

    func testForegroundHookRunsTheOneShotMigrationGatedOnProtectedData() throws {
        let app = try readSource(.appViewModel)
        let foreground = try sourceBlock(
            in: app,
            startingAt: "func setAppForegroundActive(_ active: Bool) {",
            endingBefore: "func reconcilePendingFilterSwitch()"
        )
        // The migration re-encrypts content, so it may only run once protected data is
        // available — and it must follow the INV-PERSIST-1 recovery reload, which is what
        // heals a still-blocked launch load first.
        XCTAssertTrue(
            sourceContainsInOrder([
                "reloadSharedStateIfBlockedByDataProtection()",
                "if UIApplication.shared.isProtectedDataAvailable, let containerURL = LavaSecAppGroup.containerURL {",
                "ControlPlaneProtectionMigration.run(containerURL: containerURL)",
            ], in: foreground),
            "The foreground hook must run the one-shot migration post-unlock, after the blocked-load recovery re-check (INV-PERSIST-2)."
        )
    }

    func testApplyControlPlaneProtectionVerifiesTheAppliedClass() throws {
        // The re-stamp's success path lives in the `#if os(iOS)` branch the macOS CI compiler
        // never sees, so it is pinned as source. It must RE-READ the protection class after the
        // setAttributes and only report success when it is verified Class-None: a setAttributes
        // that returns without throwing yet leaves the file Class C would otherwise let the
        // one-shot migration LATCH a still-locked control-plane file, silently reopening the
        // reboot-before-first-unlock window (INV-PERSIST-2; lavasec-infra reboot-first-unlock
        // incident plan).
        let helper = try readSource(.sharedStateFileProtection)
        let apply = try sourceBlock(
            in: helper,
            startingAt: "public static func applyControlPlaneProtection("
        )
        let setIdx = try XCTUnwrap(
            apply.range(of: "setAttributes(")?.lowerBound,
            "The apply must set the protection attribute."
        )
        let reReadIdx = try XCTUnwrap(
            apply.range(of: "attributesOfItem(atPath: url.path)")?.lowerBound,
            "The apply must re-read the file's attributes to verify the applied class."
        )
        XCTAssertLessThan(setIdx, reReadIdx,
                          "The verify re-read must FOLLOW the setAttributes write, not precede it.")
        XCTAssertTrue(
            apply.contains("applied == FileProtectionType.none"),
            "The apply must require the re-read class to be Class-None before returning success."
        )
    }
}
