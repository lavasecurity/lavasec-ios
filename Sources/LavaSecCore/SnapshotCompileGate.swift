import Foundation

/// Serializes the in-extension snapshot compile so at most one compile peak is resident at a
/// time (CON-3).
///
/// The tunnel's `loadSnapshotInBackground` spawns a detached compile per reload and only
/// generation-fences the COMMIT — a superseded compile still runs to completion. Two reloads
/// that overlap (e.g. a first-start compile after a parser-rules bump still running when a
/// user pull-to-refresh requests another) therefore hit two concurrent streaming compiles,
/// each with a ~32 MiB peak, ≈60 MiB in the 50 MB-limited NetworkExtension process → jetsam
/// kills the tunnel mid-serve. This gate holds exclusivity across the WHOLE compile so the two
/// peaks can never coincide; the caller separately re-checks its reload generation immediately
/// before entering the gate so a doomed compile is skipped rather than queued.
///
/// An `actor` alone would NOT serialize the work: an actor method releases isolation at every
/// `await`, so `await compile()` would let a second call interleave. Instead each submission
/// chains a `Task` that first awaits the previous submission's task, then runs its own body —
/// so the bodies run strictly one-at-a-time, in submission order. The chain never deadlocks:
/// a new submission only ever awaits a task that was created BEFORE it (never itself), and each
/// task always completes (the body cannot suspend on the gate again — callers wrap only the
/// compile, not a nested `run`).
public actor SnapshotCompileGate {
    /// The most recently submitted operation's task. A new submission awaits this before it
    /// starts, then becomes the new tail. Erased to `Void`/`Never` so heterogeneous result
    /// types can chain through one field.
    private var tail: Task<Void, Never>?

    public init() {}

    /// Runs `operation` after every previously submitted operation has finished, and returns
    /// its result. Preserves throwing: a body that throws rethrows to its own caller without
    /// breaking the chain (the tail task itself never throws — it captures the outcome).
    public func run<T: Sendable>(
        _ operation: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let predecessor = tail
        let task = Task<Result<T, Error>, Never> {
            // Wait out the previous compile so only one peak is resident at a time. `Never`
            // failure ⇒ awaiting it cannot throw or be cancelled out from under us.
            await predecessor?.value
            do {
                return .success(try await operation())
            } catch {
                return .failure(error)
            }
        }
        // Erase to the chainable tail: the next submission waits on THIS body finishing.
        tail = Task { _ = await task.value }
        return try await task.value.get()
    }
}
