import Foundation

/// Main-actor single-flight coordination for protection-status reloads.
///
/// A caller that arrives during the first pass joins the owner's task and requests one follow-up.
/// The owner performs at most that one extra pass, preserving the existing storm bound. Callers
/// arriving during the follow-up still await the same owner but cannot extend it into a third pass.
@MainActor
public final class ProtectionStatusRefreshCoordinator {
    private struct InFlight {
        let generation: UInt64
        let task: Task<Void, Never>
    }

    private var generation: UInt64 = 0
    private var inFlight: InFlight?
    private var acceptsFollowUp = false
    private var followUpRequested = false

    /// Creates an idle refresh coordinator.
    public init() {}

    /// Runs or joins the bounded refresh owner, awaiting its queued follow-up before returning.
    public func run(operation: @escaping @MainActor () async -> Void) async {
        if let inFlight {
            if acceptsFollowUp {
                followUpRequested = true
            }
            await inFlight.task.value
            return
        }

        generation &+= 1
        let ownerGeneration = generation
        acceptsFollowUp = true
        followUpRequested = false

        let task = Task { @MainActor [weak self] in
            defer {
                self?.finish(generation: ownerGeneration)
            }

            await operation()
            guard let self, self.followUpRequested else {
                return
            }

            // Consume exactly one queued pass. New followers still join this task, but cannot turn
            // status notifications emitted by the reload into an unbounded self-post loop.
            self.acceptsFollowUp = false
            self.followUpRequested = false
            await operation()
        }
        inFlight = InFlight(generation: ownerGeneration, task: task)
        await task.value
    }

    private func finish(generation finishedGeneration: UInt64) {
        guard inFlight?.generation == finishedGeneration else {
            return
        }
        inFlight = nil
        acceptsFollowUp = false
        followUpRequested = false
    }
}
