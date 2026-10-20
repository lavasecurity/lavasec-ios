import Foundation

/// Preserves an already-earlier background request. Submitting the same identifier
/// replaces the system's pending request, so recurring app backgrounds must not
/// keep moving its eligibility date forward. All callers share one coordinator.
public actor BackgroundTaskScheduleCoordinator {
    /// Platform-independent request metadata; the app adapter selects the task type.
    public struct Request: Equatable, Sendable {
        /// Registered system task identifier.
        public let identifier: String
        /// Eligibility floor, or nil when recovery should add no delay.
        public let earliestBeginDate: Date?

        /// Creates a proposed request without scheduling it.
        public init(identifier: String, earliestBeginDate: Date?) {
            self.identifier = identifier
            self.earliestBeginDate = earliestBeginDate
        }
    }

    /// Result of comparing and, when necessary, submitting a request.
    public enum Outcome: Equatable, Sendable {
        /// The platform accepted the request.
        case submitted
        /// An existing request is eligible at least as early.
        case keptEarlierRequest
        /// The task's kill switch was enabled before submission.
        case disabled
        /// Submission failed; subsequent scheduling calls may retry.
        case failed
    }

    private let pendingRequests: @Sendable () async -> [Request]
    private let submit: @Sendable (Request) async throws -> Void
    private let isEnabled: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private var queue: [(Request, CheckedContinuation<Outcome, Never>)] = []
    private var isDraining = false

    // Internal observation for deterministic overlap tests; no scheduling mutation.
    var queuedRequestCount: Int { queue.count }

    /// Supplies the system scheduling port and a live kill-switch lookup.
    public init(
        pendingRequests: @escaping @Sendable () async -> [Request],
        submit: @escaping @Sendable (Request) async throws -> Void,
        isEnabled: @escaping @Sendable (String) -> Bool,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.pendingRequests = pendingRequests
        self.submit = submit
        self.isEnabled = isEnabled
        self.now = now
    }

    /// Serializes the system read and submission, completing after this request is handled.
    public func schedule(_ request: Request) async -> Outcome {
        await withCheckedContinuation { continuation in
            queue.append((request, continuation))
            guard !isDraining else { return }
            isDraining = true
            Task { await drain() }
        }
    }

    private func drain() async {
        // Keep the read-and-submit operation serial across suspension points. Actor
        // isolation alone would allow two callers to read the same old queue and
        // let a routine request overwrite a just-submitted recovery request.
        while !queue.isEmpty {
            let (request, continuation) = queue.removeFirst()
            let pending = await pendingRequests()
            // Recheck after the asynchronous system read, immediately before submit.
            guard isEnabled(request.identifier) else {
                continuation.resume(returning: .disabled)
                continue
            }
            // An overdue dated request is already as eligible as immediate recovery.
            // Do not replace it merely because recovery expresses "now" with nil.
            let eligibleBy = max(now(), request.earliestBeginDate ?? .distantPast)
            if pending.contains(where: {
                $0.identifier == request.identifier
                    && ($0.earliestBeginDate ?? .distantPast) <= eligibleBy
            }) {
                continuation.resume(returning: .keptEarlierRequest)
                continue
            }
            do {
                try await submit(request)
                continuation.resume(returning: .submitted)
            } catch {
                // Do not remember a failed submission as pending: a later call retries.
                continuation.resume(returning: .failed)
            }
        }
        isDraining = false
    }
}
