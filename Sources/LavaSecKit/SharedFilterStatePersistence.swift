import Foundation

/// The single source of truth for persisting the shared `(configuration, library)` PAIR: bump the
/// configuration generation past the on-disk value, stamp the library to pair with it, and write both
/// files atomically in the fail-safe order.
///
/// Extracted (Phase 3, "share the core") so the foreground persist paths
/// (`AppViewModel.persistSharedState` / `persistConfigurationOnly`) and the headless warm-switch service
/// commit IDENTICAL write-ordering + generation-token semantics and can never drift. Pure file I/O over
/// value types — no `AppViewModel`, no `@Published`, no actor — so it is callable from the background
/// command-service context as well as the main actor. Takes the two file URLs explicitly so it stays in
/// LavaSecCore (auto-compiled + unit-testable) without depending on the app-side App Group constants.
///
/// SERIALIZATION INVARIANT (see `SharedConfigurationWriterInvariantSourceTests`):
/// `writeConfigurationAndLibrary` is SYNCHRONOUS — it reads the on-disk generation and writes BOTH files
/// with NO `await`/suspension in between — so each call is one indivisible slice WITHIN a process. Through
/// Phase 3 that was sufficient: every production caller was a `@MainActor AppViewModel` publisher and the
/// Focus App Intent executed IN the same app process, so all writers shared the one main-actor executor
/// and serialized.
///
/// CROSS-PROCESS CAS (LAV-100 Phase 4): the App Intents EXTENSION is now a SECOND writer process, so the
/// @MainActor funnel no longer serializes everything — two processes could read the same on-disk
/// generation and interleave the two file writes, producing a same-generation mismatched (config, library)
/// pair or a lost update. To close that, callers pass `crossProcessLockURL` and the read-generation
/// -then-write critical section runs under an exclusive `flock` on that file. Taken by BOTH the foreground
/// publishers AND the extension's commit, it makes the slice indivisible ACROSS processes too — restoring
/// the "no two writers read the same generation, no interleave" guarantee. `nil` (tests / a caller with no
/// container) degrades to the in-process-only behavior. The tunnel only READS the pair. The lock now adds
/// mutual exclusion; RECENCY still comes from the monotonic generation bump (read under the same lock).
///
/// LOCK ORDERING (Kilo #29): a Focus/App Intents commit acquires locks in this strict order —
/// `focusSwitchLock` (HeadlessFocusFilterSwitchEngine.withFocusSwitchLock) → the cross-process
/// configuration-write flock (`crossProcessLockURL`, taken here or by a surrounding publication
/// transaction that passes nil to avoid reacquisition) → the artifact `publishLock` (FilterPublishLock, taken in `FilterSnapshotPreparationService.persistArtifacts`).
/// The FOREGROUND publisher takes only the latter two and NEVER `focusSwitchLock`, so the two contexts
/// can't form a cycle and there is no deadlock today. Any future change that makes a holder of a LATER
/// lock acquire an EARLIER one (e.g. taking `focusSwitchLock` while holding the write flock or publish
/// lock) would introduce a lock-order inversion — preserve the order above.
public enum SharedFilterStatePersistence {
    /// Bump `configuration.configurationGeneration` to one past the max of its current value and the
    /// on-disk value (monotonic across an in-memory reset / a backup restore — see
    /// `AppConfiguration.configurationGeneration`), stamp `library.configurationGeneration` to match it,
    /// and write both files atomically.
    ///
    /// Ordering: the library (source of truth) is written FIRST, except for a restore
    /// (`prioritizesConfigurationDurability`), which writes the unreconstructable device-global config
    /// first. Each library write is stamped with the config generation it pairs with, so a kill between
    /// the two files is reconciled on load (`FilterLibrary.lostWriteRace`). Exactly one physical config
    /// write either way. Returns the values AS WRITTEN (generation bumped + stamped) so an in-memory
    /// caller can sync its published state to match disk.

    /// Thrown by `writeConfigurationAndLibrary(rejectsAdvancedBeyond:)` when the on-disk generation advanced
    /// past the fenced value — a concurrent writer won, so the caller must abort rather than clobber it
    /// (LAV-100 Phase 4).
    public struct StaleBaseGenerationError: Error {
        /// Creates the marker error used when a generation fence loses a concurrent-write race.
        public init() {}
    }

    /// Thrown when the write would replace an existing file whose content cannot currently be read —
    /// Data Protection before first unlock, or a transient I/O failure (INV-PERSIST-1). A caller in
    /// that state loaded "defaults" from a failed read; letting the write proceed would stamp them at
    /// a winning generation over the user's real data (the 2026-07-14 reboot filter-library wipe).
    /// Thrown by `writeConfigurationAndLibrary(refusesIfOnDiskActiveFilterIs:)` when the filter the
    /// caller is about to overwrite is, at write time, the one PERSISTED as active.
    ///
    /// The in-memory `activeFilterID` is not sufficient to decide this. A headless Focus or Shortcut
    /// switch commits from another process and the foreground adopts it asynchronously off a Darwin
    /// notification, so `AppViewModel.library` can still name the previous filter while disk names
    /// the new one. A caller that checked only its own snapshot could therefore replace the filter
    /// that is protecting the device, and overwrite the newer switch, believing it had picked an
    /// idle one. Evaluated under the same lock as the write so the answer cannot change in between.
    public struct ActiveFilterChangedError: Error {
        /// The filter that turned out to be active on disk.
        public let activeFilterID: String

        public init(activeFilterID: String) {
            self.activeFilterID = activeFilterID
        }
    }

    public struct ExistingStateUnreadableError: Error {
        /// Creates the marker error used when the on-disk pair exists but is unreadable.
        public init() {}
    }

    /// Persists a generation-matched configuration/library pair under the optional cross-process lock.
    ///
    /// - Throws: ``StaleBaseGenerationError`` when the fenced on-disk generation has already advanced,
    ///   or a serialization or file-write error.
    /// - Returns: The configuration and library values exactly as written, including their new generation.
    @discardableResult
    public static func writeConfigurationAndLibrary(
        configuration: AppConfiguration,
        library: FilterLibrary,
        configurationURL: URL,
        filterLibraryURL: URL,
        prioritizesConfigurationDurability: Bool = false,
        // Cross-process CAS lock (LAV-100 Phase 4): when non-nil, the read-generation-then-write critical
        // section runs under an exclusive flock on this file so the foreground publishers and the App
        // Intents extension can never interleave. `nil` degrades to in-process-only (tests / no container).
        crossProcessLockURL: URL? = nil,
        // Generation-fenced CAS (LAV-100 Phase 4): when non-nil, ABORT (throw `StaleBaseGenerationError`) if
        // the on-disk generation has advanced PAST `rejectsAdvancedBeyond` — i.e. another process committed
        // since the value this caller is fencing against. TWO extension callers use it, with DIFFERENT fence
        // values:
        //   • the forward commit passes its LOADED BASE generation — it loads `(configuration, library)`, then
        //     awaits warm validation before writing; without the fence it would blindly write its STALE
        //     device-global config back at a higher generation, silently reverting a concurrent foreground
        //     change.
        //   • the ROLLBACK (after a vetoed/failed commit) passes the generation IT JUST WROTE — so it reverts
        //     ONLY its own write; if a foreground writer advanced the on-disk generation past that in the gap
        //     between the config write and the rollback, the rollback aborts and leaves the newer state (it
        //     would otherwise re-bump the generation and clobber the user's update).
        // `nil` skips the fence. Reviewed restores retain the current device's generation and pass
        // the reviewed basis here. Foreground library-only writers pass their loaded generation so
        // a newer headless switch cannot be replaced by their stale whole pair; foreground active/config
        // publishers keep their existing explicit ownership and publication reconciliation semantics.
        rejectsAdvancedBeyond: Int? = nil,
        // In-lock active-filter precondition: when non-nil, ABORT (throw `ActiveFilterChangedError`) if
        // the filter PERSISTED as active is this id. Used by callers that may only touch an IDLE filter
        // — the shared-filter import's library-only replace — where the in-memory `activeFilterID` is an
        // asynchronously-reconciled snapshot and can lag a headless Focus/Shortcut commit. Checked here,
        // atomically with the write, because a caller-side check is a different question answered at a
        // different time. `nil` (every other caller) skips it and behaves exactly as before.
        refusesIfOnDiskActiveFilterIs: String? = nil
    ) throws -> (configuration: AppConfiguration, library: FilterLibrary) {
        // The ENTIRE generation read + bump + both-file writes must be one critical section across
        // processes — splitting the read from the write would let a second process bump in between.
        try FilterPublishLock.withExclusiveLock(at: crossProcessLockURL) {
            // INV-PERSIST-1 writer-side backstop (pinned: SharedFilterStatePersistenceTests.testWriteRefusesToReplaceExistingUnreadableConfig): refuse to
            // replace state that EXISTS but cannot be READ (Data Protection before first unlock, or a
            // transient I/O failure). A caller holding such state seeded its in-memory values from a
            // failed read; writing them would destroy the user's real files at a winning generation —
            // the 2026-07-14 reboot wipe. Readable-but-corrupt files still write (deliberate corruption
            // recovery), and absent files are a normal first write. Checked under the lock so the
            // classification is atomic with the write it guards.
            if SharedStateFileReader.fileExistsButIsUnreadable(at: configurationURL)
                || SharedStateFileReader.fileExistsButIsUnreadable(at: filterLibraryURL) {
                throw ExistingStateUnreadableError()
            }
            // Generation fence UNDER the lock (atomic with the read+write): a write whose fence value lost the
            // race to a newer cross-process write must not be overwritten/re-bumped at a higher generation.
            if let rejectsAdvancedBeyond,
               onDiskConfigurationGeneration(at: configurationURL) > rejectsAdvancedBeyond {
                throw StaleBaseGenerationError()
            }
            // Active-filter precondition UNDER the lock, for the same reason as the fence above: a
            // concurrent cross-process switch must not be discoverable only after the write.
            if let refusesIfOnDiskActiveFilterIs,
               onDiskActiveFilterID(at: filterLibraryURL) == refusesIfOnDiskActiveFilterIs {
                throw ActiveFilterChangedError(activeFilterID: refusesIfOnDiskActiveFilterIs)
            }
            var nextConfiguration = configuration
            // Trapping `+ 1` (not `&+`): a generation overflow is a real bug worth trapping, not silently
            // wrapping to a negative value that would corrupt monotonicity. Unreachable on 64-bit Int in
            // practice, and consistent with the surrounding `max(...)` normal arithmetic (review #9).
            nextConfiguration.configurationGeneration =
                max(configuration.configurationGeneration, onDiskConfigurationGeneration(at: configurationURL)) + 1

            var nextLibrary = library
            nextLibrary.configurationGeneration = nextConfiguration.configurationGeneration

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let libraryData = try encoder.encode(nextLibrary)
            let configurationData = try encoder.encode(nextConfiguration)

            // Library-first (source of truth before its derived cache) for a normal edit; a restore
            // prioritizes the unreconstructable device-global config, writing it first. EXACTLY ONE physical
            // configuration write either way — the library write is what moves to the other side
            // (SharedConfigurationWriterInvariant). Both files are control-plane state a
            // Connect-On-Demand boot tunnel must read before first unlock, so the options carry
            // NSFileProtectionNone alongside .atomic (INV-PERSIST-2).
            if !prioritizesConfigurationDurability {
                try libraryData.write(to: filterLibraryURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            }
            try configurationData.write(to: configurationURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            if prioritizesConfigurationDurability {
                try libraryData.write(to: filterLibraryURL, options: SharedStateFileProtection.atomicControlPlaneWritingOptions)
            }
            return (nextConfiguration, nextLibrary)
        }
    }

    /// The `configurationGeneration` currently persisted at `configurationURL`, or 0 if there is no
    /// readable configuration yet. Read just before a write to keep the bump monotonic across resets.
    public static func onDiskConfigurationGeneration(at configurationURL: URL) -> Int {
        guard let data = try? Data(contentsOf: configurationURL),
              let persisted = try? JSONDecoder().decode(AppConfiguration.self, from: data) else {
            return 0
        }
        return persisted.configurationGeneration
    }

    /// The `activeFilterID` currently persisted in `filter-library.json`, or nil if it is unreadable.
    ///
    /// Read UNDER the artifact publish lock by the foreground flip fence (LAV-100 Phase 4): now that the App
    /// Intents extension can commit + flip a switch concurrently (state-agnostic), a foreground publish must
    /// confirm the on-disk selection is STILL the filter its staged artifact is for before flipping the
    /// pointer — otherwise it could overwrite a newer Focus pointer with its stale-basis artifact. Compares
    /// the active filter (not the raw generation) so a concurrent library-only generation bump that KEPT the
    /// same filter active — a warm-token promote — does not needlessly abort the flip.
    public static func onDiskActiveFilterID(at filterLibraryURL: URL) -> String? {
        guard let data = try? Data(contentsOf: filterLibraryURL),
              let library = try? JSONDecoder().decode(FilterLibrary.self, from: data) else {
            return nil
        }
        return library.activeFilterID
    }

    /// The on-disk active filter's `lastCompiledToken`, or nil if unreadable / the active filter is cold.
    ///
    /// The foreground disk-adopt (LAV-100) compares this to the live artifact POINTER token to confirm a
    /// headless commit actually COMPLETED: the extension writes config+library (bumping the generation) and
    /// flips the artifact pointer LAST, so a higher on-disk generation alone can be the config-leads-pointer
    /// window where the extension may still roll back. Only when the pointer names the active filter's
    /// compiled artifact is the switch durable enough to adopt (else the adopt could clear the marker for a
    /// switch that never lands).
    public static func onDiskActiveFilterCompiledToken(at filterLibraryURL: URL) -> String? {
        guard let data = try? Data(contentsOf: filterLibraryURL),
              let library = try? JSONDecoder().decode(FilterLibrary.self, from: data) else {
            return nil
        }
        return library.filter(id: library.activeFilterID)?.lastCompiledToken
    }
}
