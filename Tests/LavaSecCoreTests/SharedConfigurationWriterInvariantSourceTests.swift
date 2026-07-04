import XCTest

/// Structural invariant guarding the shared `app-configuration.json` against the config-clobber race
/// that forced the daily background catalog refresh out of 1.0 (removal commit 0e15882, #65; LAV-90).
///
/// The PRIMARY fix is structural: every writer of the shared configuration funnels through the ONE
/// shared writer, `SharedFilterStatePersistence.writeConfigurationAndLibrary`. That is the only place the
/// file is physically written; the `@MainActor AppViewModel` is the only foreground owner (its two
/// publishers delegate to the writer). Through Phase 3 the Focus switch ran in the same app process, so
/// the @MainActor funnel serialized every writer and no lock was needed.
///
/// LAV-100 Phase 4 adds the App Intents EXTENSION as a real SECOND writer process — the @MainActor funnel
/// can no longer span it — so the single writer's read-generation-then-write critical section is now
/// wrapped in a cross-process CAS lock (`crossProcessLockURL`, the `configuration-write` flock), taken by
/// BOTH the foreground publishers and the extension's commit. The lock supplies the cross-process mutual
/// exclusion; RECENCY still comes from the monotonic generation bump read UNDER that lock. This test fails
/// loudly if a raw config write reappears outside the shared writer, if the owner leaves the main actor,
/// or if a foreground publisher stops passing the cross-process lock.
final class SharedConfigurationWriterInvariantSourceTests: XCTestCase {
    private let writeMarker = "write(to: configurationURL"

    func testConfigurationIsWrittenOnlyByTheSingleSharedWriter() throws {
        let appViewModel = try readSource(.appViewModel)
        let writer = try readSource(.sharedFilterStatePersistence)

        // The single owner of the shared configuration file must stay main-actor confined, so no
        // background-constructed model can race a foreground save through the published state.
        XCTAssertTrue(
            appViewModel.contains("@MainActor\nfinal class AppViewModel: ObservableObject {"),
            "AppViewModel must remain @MainActor so its configuration writes cannot run off the main actor (LAV-90 config-clobber)."
        )

        // The physical configuration write must exist in EXACTLY ONE place — the shared writer.
        XCTAssertEqual(
            writer.components(separatedBy: writeMarker).count - 1, 1,
            "SharedFilterStatePersistence must contain exactly one physical configuration write."
        )

        // …and NOWHERE else. A raw config write outside the shared writer is precisely the
        // uncoordinated-writer regression this test exists to catch.
        XCTAssertEqual(
            appViewModel.components(separatedBy: writeMarker).count - 1, 0,
            "AppViewModel must not write the configuration directly — it delegates to SharedFilterStatePersistence (LAV-90)."
        )

        // Both foreground publishers must delegate to the shared writer (and only those two do so in
        // AppViewModel — a third foreground delegate would be a new write path to scrutinize).
        let delegateMarker = "SharedFilterStatePersistence.writeConfigurationAndLibrary("
        let persistSharedState = try sourceBlock(
            in: appViewModel,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )
        XCTAssertEqual(
            persistSharedState.components(separatedBy: delegateMarker).count - 1, 1,
            "persistSharedState must persist via exactly one shared-writer call."
        )
        let persistConfigurationOnly = try sourceBlock(
            in: appViewModel,
            startingAt: "private func persistConfigurationOnly(",
            endingBefore: "private func syncActiveFilterFromConfiguration()"
        )
        XCTAssertEqual(
            persistConfigurationOnly.components(separatedBy: delegateMarker).count - 1, 1,
            "persistConfigurationOnly must persist via exactly one shared-writer call."
        )
        XCTAssertEqual(
            appViewModel.components(separatedBy: delegateMarker).count - 1, 2,
            "Exactly the two foreground publishers may delegate to the shared writer; a third AppViewModel caller risks config-clobber (LAV-90)."
        )
    }

    /// Pin the LIBRARY half too. EVERY library write — the pair write AND the library-only edit path
    /// (rename/delete/create/warm-token-promote, `persistFilterLibrary`) — is single-sourced through the
    /// ONE shared pair writer. The library-only path routes through `persistConfigurationOnly` (one of the
    /// two delegating publishers), which ADVANCES the shared generation: a write that left the config
    /// generation unbumped would not trip the App Intents extension's stale-reader fence, so the extension
    /// could overwrite a concurrent foreground library edit with its stale snapshot (Codex P1, state-agnostic
    /// switch). AppViewModel must therefore contain ZERO raw library writes — the library is only ever written
    /// by the shared writer, at a bumped generation.
    func testLibraryHalfOfThePairIsAlsoSingleSourced() throws {
        let appViewModel = try readSource(.appViewModel)
        let writer = try readSource(.sharedFilterStatePersistence)
        let libraryWriteMarker = "write(to: filterLibraryURL"

        XCTAssertTrue(
            writer.contains(libraryWriteMarker),
            "The shared writer must own every library write."
        )
        XCTAssertEqual(
            appViewModel.components(separatedBy: libraryWriteMarker).count - 1, 0,
            "AppViewModel must contain NO raw library writes — every library write (pair or library-only) goes through the shared pair writer at a bumped generation."
        )
        // The library-only edit path must NOT do an un-bumped library-only write: it delegates to
        // persistConfigurationOnly so the generation advances and the extension's fence can trip (Codex P1).
        let persistFilterLibrary = try sourceBlock(
            in: appViewModel,
            startingAt: "private func persistFilterLibrary(",
            endingBefore: "private func uploadEncryptedBackup("
        )
        XCTAssertEqual(
            persistFilterLibrary.components(separatedBy: "persistConfigurationOnly(").count - 1, 1,
            "persistFilterLibrary must persist via persistConfigurationOnly (a generation-bumping pair write), not an un-bumped library-only write."
        )
        // The shared pair writer must stay SYNCHRONOUS: an await between the on-disk generation read and the
        // two file writes would reopen the interleave/same-generation window the @MainActor serialization
        // closes. Assert the function signature is non-async and its body has no await.
        XCTAssertTrue(
            writer.contains("public static func writeConfigurationAndLibrary("),
            "The shared pair writer must exist."
        )
        let writerBody = try sourceBlock(
            in: writer,
            startingAt: "public static func writeConfigurationAndLibrary(",
            endingBefore: "public static func onDiskConfigurationGeneration("
        )
        XCTAssertFalse(writerBody.contains(" async "),
                       "The pair writer must stay synchronous (no async) — a suspension would reopen the interleave window.")
        XCTAssertFalse(writerBody.contains("await "),
                       "The pair writer must not await between the generation read and the two file writes (atomic slice).")
    }

    /// LAV-100 Phase 4 P4c: with the App Intents extension as a second writer process, the single shared
    /// writer's critical section must run under a cross-process flock, and BOTH foreground publishers (plus
    /// the extension's engine) must pass that lock — otherwise the two processes can interleave the
    /// generation read + file writes. Pin the lock wrap + that the foreground publishers engage it.
    func testCrossProcessCASLockWrapsTheCriticalSectionAndAllWritersEngageIt() throws {
        let appViewModel = try readSource(.appViewModel)
        let writer = try readSource(.sharedFilterStatePersistence)
        let engine = try readSource(.headlessFocusFilterSwitchEngine)

        // The writer wraps its read-generation-then-write critical section in the exclusive flock.
        XCTAssertTrue(writer.contains("crossProcessLockURL: URL? = nil"),
                      "The shared writer must accept a cross-process lock URL.")
        XCTAssertTrue(writer.contains("FilterPublishLock.withExclusiveLock(at: crossProcessLockURL)"),
                      "The shared writer must run its critical section under an exclusive cross-process lock.")

        // Both foreground publishers must engage the lock (a publisher that omits it can interleave with the
        // extension). Exactly two foreground call sites pass the lock — matching the two delegating publishers.
        let lockArg = "crossProcessLockURL: containerURL.appendingPathComponent(LavaSecAppGroup.configurationWriteLockFilename)"
        XCTAssertEqual(appViewModel.components(separatedBy: lockArg).count - 1, 2,
                       "Both foreground publishers (persistSharedState + persistConfigurationOnly) must pass the cross-process lock.")

        // The extension engine must engage the SAME lock on both its commit and its rollback writer.
        XCTAssertEqual(engine.components(separatedBy: "crossProcessLockURL: env.configurationWriteLockURL").count - 1, 2,
                       "The engine's commit AND rollback writer must pass the cross-process lock.")
    }

    /// LAV-100 Phase 4 (Codex P1, state-agnostic switch): the cross-process WRITE lock is released before the
    /// artifact PUBLISH lock is taken, so the App Intents extension can commit + flip a NEWER switch in that
    /// gap. The foreground publish must therefore FENCE its flip — confirm the on-disk active filter is still
    /// the one its staged artifact is for before flipping — or it could overwrite the newer Focus pointer with
    /// its stale-basis artifact (config selecting the Focus target while the live pointer names the foreground
    /// snapshot). Mirrors the engine's symmetric in-flip fence. Pin that persistSharedState passes the fence,
    /// and that it keys on the ACTIVE FILTER (so a concurrent library-only generation bump — a warm-token
    /// promote, which has no marker to recover an aborted flip — does not needlessly abort the flip).
    func testForegroundFlipIsFencedAgainstAConcurrentSwitch() throws {
        let appViewModel = try readSource(.appViewModel)
        let writer = try readSource(.sharedFilterStatePersistence)

        let persistSharedState = try sourceBlock(
            in: appViewModel,
            startingAt: "private func persistSharedState(",
            endingBefore: "private func persistConfigurationOnly("
        )
        XCTAssertTrue(persistSharedState.contains("supersededWhileLocked:"),
                      "The foreground publish must pass a flip fence (supersededWhileLocked) so a concurrent Focus commit isn't clobbered.")
        XCTAssertTrue(persistSharedState.contains("SharedFilterStatePersistence.onDiskActiveFilterID(at: filterLibraryURL)"),
                      "The flip fence must read the on-disk ACTIVE filter (not the raw generation) to detect a concurrent switch.")
        XCTAssertTrue(persistSharedState.contains("onDiskActive != flipTargetFilterID"),
                      "The flip must abort only when the on-disk active filter differs from the one being published.")
        XCTAssertTrue(writer.contains("public static func onDiskActiveFilterID(at filterLibraryURL: URL) -> String?"),
                      "The shared persistence must expose the on-disk active-filter reader for the flip fence.")
    }

    // MARK: - Source introspection helpers
}
