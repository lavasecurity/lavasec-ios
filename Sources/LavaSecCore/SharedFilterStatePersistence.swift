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
    public struct StaleBaseGenerationError: Error { public init() {} }

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
        // `nil` (foreground / restore callers) SKIPS the fence — they are the single-owner @MainActor writer
        // (restore deliberately writes from a LOWER base via the monotonic bump, which a fence would reject).
        rejectsAdvancedBeyond: Int? = nil
    ) throws -> (configuration: AppConfiguration, library: FilterLibrary) {
        // The ENTIRE generation read + bump + both-file writes must be one critical section across
        // processes — splitting the read from the write would let a second process bump in between.
        try FilterPublishLock.withExclusiveLock(at: crossProcessLockURL) {
            // Generation fence UNDER the lock (atomic with the read+write): a write whose fence value lost the
            // race to a newer cross-process write must not be overwritten/re-bumped at a higher generation.
            if let rejectsAdvancedBeyond,
               onDiskConfigurationGeneration(at: configurationURL) > rejectsAdvancedBeyond {
                throw StaleBaseGenerationError()
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
            // (SharedConfigurationWriterInvariant).
            if !prioritizesConfigurationDurability {
                try libraryData.write(to: filterLibraryURL, options: [.atomic])
            }
            try configurationData.write(to: configurationURL, options: [.atomic])
            if prioritizesConfigurationDurability {
                try libraryData.write(to: filterLibraryURL, options: [.atomic])
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
