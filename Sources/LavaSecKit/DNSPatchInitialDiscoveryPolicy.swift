import Foundation

/// Tracks the first physical-path evaluation without equating empty observations
/// with readiness. The owner bounds monitor and connection callbacks with one deadline.
public struct DNSPatchInitialDiscoveryPolicy: Sendable {
    /// Total initial evaluation budget, including an absent first monitor callback.
    public static let timeoutSeconds: TimeInterval = 5

    /// The two physical transports evaluated by DNS patch discovery.
    public enum Interface: Int, Hashable, Sendable {
        case wifi
        case cellular
    }

    /// A bounded initial evaluation must fail explicitly when capture is unknown.
    public enum Failure: String, Error, Equatable, Sendable {
        case timedOut = "timed-out"
        case evaluationFailed = "evaluation-failed"
        case cancelled
    }

    /// Exactly one terminal result for an initial discovery lifecycle.
    public enum Completion: Equatable, Sendable {
        case succeeded
        case failed(Failure)
    }

    /// A replacement evaluation token, a terminal result, or no new initial work.
    public enum Action: Equatable, Sendable {
        case none
        case evaluate(UInt64)
        case complete(Completion)
    }

    private enum State: Equatable, Sendable {
        case awaitingPath
        case evaluating(UInt64)
        case settled
    }

    private var states: [Interface: State] = [.wifi: .awaitingPath, .cellular: .awaitingPath]
    private var nextToken: UInt64 = 0
    private var isFinished = false

    /// Starts with neither physical interface's initial state known.
    public init() {}

    /// Inactive paths settle without an endpoint. An active path must obtain an
    /// admitted endpoint; a replacement path retires its earlier evaluation token.
    @discardableResult
    public mutating func pathObserved(_ interface: Interface, isSatisfied: Bool) -> Action {
        guard !isFinished else { return .none }
        if !isSatisfied {
            states[interface] = .settled
            return completeIfSettled()
        }
        nextToken += 1
        states[interface] = .evaluating(nextToken)
        return .evaluate(nextToken)
    }

    /// A usable endpoint settles its matching evaluation. Missing/rejected endpoints
    /// and connection failure cannot authorize startup with unknown capture routes.
    public mutating func evaluationCompleted(
        _ interface: Interface, token: UInt64, endpointIsAdmitted: Bool
    ) -> Action {
        guard !isFinished, states[interface] == .evaluating(token) else { return .none }
        guard endpointIsAdmitted else { return finish(.failed(.evaluationFailed)) }
        states[interface] = .settled
        return completeIfSettled()
    }

    /// Ends the entire initial budget, including monitor silence and pending evaluations.
    public mutating func deadlineDidExpire() -> Action {
        guard !isFinished else { return .none }
        return finish(.failed(.timedOut))
    }

    /// Cancels once; later connection, monitor and deadline results have no authority.
    public mutating func cancel() -> Action {
        guard !isFinished else { return .none }
        return finish(.failed(.cancelled))
    }

    private mutating func completeIfSettled() -> Action {
        guard states.values.allSatisfy({ $0 == .settled }) else { return .none }
        return finish(.succeeded)
    }

    private mutating func finish(_ completion: Completion) -> Action {
        isFinished = true
        states.removeAll()
        return .complete(completion)
    }
}
